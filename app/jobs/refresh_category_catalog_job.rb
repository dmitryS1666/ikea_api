# frozen_string_literal: true

# Полная актуализация одной категории или всего опубликованного каталога:
# товары и русские атрибуты -> фасеты IKEA -> точные связи SKU/фасет -> cache bust.
class RefreshCategoryCatalogJob < ApplicationJob
  queue_as :parser

  TASK_TYPE = "refresh_category_catalog".freeze
  STAGE_MAX_ATTEMPTS = 3
  STAGE_RETRY_DELAYS = [1, 3].freeze
  TRANSIENT_ERROR_PATTERN = /(?:timeout|timed out|connection|socket|proxy|temporar|rate.?limit|HTTP\s+(?:429|5\d\d)|ECONN|EHOST|ENET|SSL)/i

  def perform(ikea_id: nil, task_id: nil, threads: 2, resume: false, retry_failed: false)
    task = task_id.present? ? ParserTask.find(task_id) : create_parser_task(TASK_TYPE)
    task.mark_as_running!

    checkpoint_run = resume || retry_failed
    task.update_payload!(RefreshCategoryFromLtJob::PRODUCT_CHECKPOINT_KEY => nil) unless checkpoint_run
    if checkpoint_run
      saved_threads = task.payload.to_h["threads"].to_i
      threads = saved_threads if saved_threads.positive?
    end
    all_categories = checkpoint_run ? checkpoint_categories(task) : sorted_categories(categories_scope(ikea_id))
    stats = build_stats(task, all_categories, checkpoint_run: checkpoint_run)
    categories = categories_for_run(all_categories, stats, retry_failed: retry_failed)

    raise "В checkpoint нет ошибочных категорий для повторной обработки" if retry_failed && categories.empty?

    persist_checkpoint!(
      task,
      stats,
      ikea_id: checkpoint_run ? task.payload.to_h["ikea_id"] : ikea_id.to_s.presence,
      threads: checkpoint_run ? task.payload.to_h["threads"].presence || threads : threads,
      stage: checkpoint_run ? (retry_failed ? "retrying_failed" : "resuming") : "started"
    )

    categories.each do |category|
      check_task_not_stopped!(task)
      begin_category_attempt!(task, category, stats)

      product_stats = with_stage_retries(task, category, "products") do
        RefreshCategoryFromLtJob.new.perform(
          ikea_id: category.ikea_id,
          task_id: task.id,
          threads: threads,
          manage_task: false
        )
      end
      stats[:products_processed_by_category][category.ikea_id.to_s] =
        product_stats.to_h.with_indifferent_access[:products_completed].presence&.to_i ||
        product_stats.to_h.with_indifferent_access[:processed].to_i
      persist_checkpoint!(task, stats, current_category: category, stage: "products_completed")

      check_task_not_stopped!(task)
      with_stage_retries(task, category, "filters") do
        Categories::LtAvailableFiltersRefreshService.new(
          category,
          reindex: false,
          ensure_series: false
        ).call
      end

      check_task_not_stopped!(task)
      facet_result = sync_facet_memberships(category, task, stats)
      stats[:facet_memberships_by_category][category.ikea_id.to_s] = facet_result.memberships_count.to_i
      if facet_result.unmatched_skus.present?
        stats[:unmatched_skus][category.ikea_id] = facet_result.unmatched_skus.first(200)
      end
      persist_checkpoint!(task, stats, current_category: category, stage: "facet_memberships_completed")

      check_task_not_stopped!(task)
      persist_checkpoint!(task, stats, current_category: category, stage: "local_filters")
      Products::FilterValuesIndexer.new(category.reload).reindex!

      # Поиск в проекте работает непосредственно по PostgreSQL и не имеет
      # отдельного Elasticsearch/Searchkick-индекса. После обновления записей
      # достаточно сбросить кеш сериализованной категории.
      bust_catalog_tree_cache!(category)

      quality_issues = product_quality_issues(category)
      missing_delivery_metrics = Array(quality_issues["missing_delivery_metrics"])
      if missing_delivery_metrics.any?
        stats[:missing_delivery_metrics][category.ikea_id] = missing_delivery_metrics.first(200)
      end
      if quality_issues.values.any?(&:present?)
        stats[:product_quality_issues][category.ikea_id] = quality_issues
      end

      mark_category_attempt_finished!(stats, category)
      persist_checkpoint!(task, stats, current_category: category, stage: "category_completed")
      task.update_payload!(RefreshCategoryFromLtJob::PRODUCT_CHECKPOINT_KEY => nil)
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"

      stats[:category_errors][category.ikea_id] = {
        "error_class" => e.class.name,
        "message" => e.message.to_s,
        "stage" => task.payload.to_h["stage"]
      }
      mark_category_failed!(stats, category)
      persist_checkpoint!(task, stats, current_category: category, stage: "category_failed")
      Rails.logger.error(
        "RefreshCategoryCatalogJob category=#{category.ikea_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
    end

    finalization_categories = categories_for_finalization(categories, all_categories)
    finalize_hierarchical_filters!(
      finalization_categories,
      all_categories.map { |category| category.ikea_id.to_s },
      task,
      stats
    )

    refresh_derived_stats!(stats)
    final_stage = if stats[:errors].positive?
                    "completed_with_errors"
                  elsif incomplete_category_ids(stats).any?
                    "incomplete"
                  else
                    "completed"
                  end
    persist_checkpoint!(task, stats, stage: final_stage)
    finish_task(task, stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    Rails.logger.error("RefreshCategoryCatalogJob: #{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    raise if task_id.blank?
  end

  private

  def sorted_categories(scope)
    scope.to_a.sort_by { |category| -Category.normalize_parent_ids(category.parent_ids).size }
  end

  def checkpoint_categories(task)
    category_ids = Array(task.payload.to_h["category_ids"]).map(&:to_s).reject(&:blank?)
    raise "У задачи нет checkpoint для продолжения" if category_ids.empty?

    index = Category.not_deleted.where(ikea_id: category_ids).index_by { |category| category.ikea_id.to_s }
    categories = category_ids.filter_map { |id| index[id] }
    raise "Категории из checkpoint больше не существуют" if categories.empty?

    categories
  end

  def build_stats(task, categories, checkpoint_run:)
    payload = checkpoint_run ? task.payload.to_h.deep_stringify_keys : {}
    category_ids = categories.map { |category| category.ikea_id.to_s }

    {
      category_ids: category_ids,
      attempted_category_ids: Array(payload["attempted_category_ids"]).map(&:to_s) & category_ids,
      completed_category_ids: Array(payload["completed_category_ids"]).map(&:to_s) & category_ids,
      failed_category_ids: Array(payload["failed_category_ids"]).map(&:to_s) & category_ids,
      products_processed_by_category: payload.fetch("products_processed_by_category", {}).to_h,
      facet_memberships_by_category: payload.fetch("facet_memberships_by_category", {}).to_h,
      unmatched_skus: payload.fetch("unmatched_skus", {}).to_h,
      missing_delivery_metrics: payload.fetch("missing_delivery_metrics", {}).to_h,
      product_quality_issues: payload.fetch("product_quality_issues", {}).to_h,
      facet_errors: payload.fetch("facet_errors", {}).to_h,
      category_errors: payload.fetch("category_errors", {}).to_h,
      processed: 0,
      updated: 0,
      errors: 0,
      products_processed: 0,
      facet_memberships: 0
    }.tap { |stats| refresh_derived_stats!(stats) }
  end

  def categories_for_run(categories, stats, retry_failed:)
    selected_ids = if retry_failed
                     stats[:failed_category_ids]
                   else
                     stats[:category_ids] - stats[:completed_category_ids]
                   end

    categories.select { |category| selected_ids.include?(category.ikea_id.to_s) }
  end

  def begin_category_attempt!(task, category, stats)
    id = category.ikea_id.to_s
    stats[:completed_category_ids].delete(id)
    stats[:failed_category_ids].delete(id)
    stats[:category_errors].delete(id)
    stats[:facet_errors].delete(id)
    stats[:unmatched_skus].delete(id)
    stats[:missing_delivery_metrics].delete(id)
    stats[:product_quality_issues].delete(id)
    stats[:products_processed_by_category].delete(id)
    stats[:facet_memberships_by_category].delete(id)
    persist_checkpoint!(task, stats, current_category: category, stage: "products")
  end

  def mark_category_attempt_finished!(stats, category)
    id = category.ikea_id.to_s
    stats[:attempted_category_ids] |= [id]

    if Array(stats[:facet_errors][id]).any?
      stats[:failed_category_ids] |= [id]
      stats[:completed_category_ids].delete(id)
    else
      stats[:completed_category_ids] |= [id]
      stats[:failed_category_ids].delete(id)
    end
  end

  def mark_category_failed!(stats, category)
    id = category.ikea_id.to_s
    stats[:attempted_category_ids] |= [id]
    stats[:failed_category_ids] |= [id]
    stats[:completed_category_ids].delete(id)
  end

  def refresh_derived_stats!(stats)
    stats[:processed] = stats[:attempted_category_ids].size
    stats[:updated] = stats[:completed_category_ids].size
    stats[:products_processed] = stats[:products_processed_by_category].values.sum(&:to_i)
    stats[:facet_memberships] = stats[:facet_memberships_by_category].values.sum(&:to_i)
    stats[:errors] = stats[:category_errors].size + stats[:facet_errors].values.sum { |errors| Array(errors).size }
    stats
  end

  def incomplete_category_ids(stats)
    stats[:category_ids] - stats[:completed_category_ids]
  end

  def persist_checkpoint!(task, stats, ikea_id: :keep, threads: :keep, current_category: nil, stage: nil)
    refresh_derived_stats!(stats)
    payload = {
      "categories_total" => stats[:category_ids].size,
      "category_ids" => stats[:category_ids],
      "attempted_category_ids" => stats[:attempted_category_ids],
      "completed_category_ids" => stats[:completed_category_ids],
      "failed_category_ids" => stats[:failed_category_ids],
      "products_processed_by_category" => stats[:products_processed_by_category],
      "facet_memberships_by_category" => stats[:facet_memberships_by_category],
      "products_processed" => stats[:products_processed],
      "facet_memberships" => stats[:facet_memberships],
      "unmatched_skus" => stats[:unmatched_skus],
      "missing_delivery_metrics" => stats[:missing_delivery_metrics],
      "product_quality_issues" => stats[:product_quality_issues],
      "facet_errors" => stats[:facet_errors],
      "category_errors" => stats[:category_errors]
    }
    payload["ikea_id"] = ikea_id unless ikea_id == :keep
    payload["threads"] = threads unless threads == :keep
    payload["current_category_ikea_id"] = current_category.ikea_id.to_s if current_category
    payload["stage"] = stage if stage

    task.update_columns(
      processed: stats[:processed],
      updated: stats[:updated],
      error_count: stats[:errors]
    )
    task.update_payload!(payload)
  end

  def with_stage_retries(task, category, stage)
    attempt = 0

    begin
      attempt += 1
      check_task_not_stopped!(task)
      task.update_payload!(
        "current_category_ikea_id" => category.ikea_id.to_s,
        "stage" => stage,
        "stage_attempt" => attempt
      )
      yield
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"
      raise unless transient_error?(e) && attempt < STAGE_MAX_ATTEMPTS

      delay = STAGE_RETRY_DELAYS.fetch(attempt - 1, STAGE_RETRY_DELAYS.last)
      task.update_payload!(
        "last_retry" => {
          "category_ikea_id" => category.ikea_id.to_s,
          "stage" => stage,
          "attempt" => attempt,
          "error_class" => e.class.name,
          "message" => e.message.to_s,
          "retry_in_seconds" => delay
        }
      )
      sleep(delay)
      retry
    end
  end

  def transient_error?(error)
    return false if error.message.to_s.include?("headless retries exhausted")

    error.class.name.match?(TRANSIENT_ERROR_PATTERN) || error.message.to_s.match?(TRANSIENT_ERROR_PATTERN)
  end

  # Дочерние категории обновляются раньше родителей. После полного прохода
  # пересобираем available_filters всех родительских узлов и локальный индекс:
  # товары потомков могли измениться уже после первого reindex родителя.
  def finalize_hierarchical_filters!(categories, scope_category_ids, task, stats)
    categories.each do |category|
      descendant_ids = category.descendant_ikea_ids & scope_category_ids
      next if descendant_ids.empty?

      check_task_not_stopped!(task)
      task.update_payload!(
        "current_category_ikea_id" => category.ikea_id,
        "stage" => "merge_hierarchical_filters"
      )

      Categories::MergeDescendantAvailableFiltersService.new(category.reload).call
      Products::FilterValuesIndexer.new(category.reload).reindex!
      bust_catalog_tree_cache!(category)
      persist_checkpoint!(task, stats, current_category: category, stage: "merge_hierarchical_filters_completed")
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"

      stats[:category_errors][category.ikea_id] = {
        "error_class" => e.class.name,
        "message" => e.message.to_s,
        "stage" => "merge_hierarchical_filters"
      }
      mark_category_failed!(stats, category)
      persist_checkpoint!(task, stats, current_category: category, stage: "merge_hierarchical_filters_failed")
      Rails.logger.error(
        "RefreshCategoryCatalogJob hierarchical filters category=#{category.ikea_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
    end
  end

  def categories_for_finalization(processed_categories, all_categories)
    relevant_ids = processed_categories.flat_map do |category|
      [category.ikea_id.to_s, *Category.normalize_parent_ids(category.parent_ids).map(&:to_s)]
    end.uniq

    all_categories.select { |category| relevant_ids.include?(category.ikea_id.to_s) }
                  .sort_by { |category| -Category.normalize_parent_ids(category.parent_ids).size }
  end

  def bust_catalog_tree_cache!(category)
    ids = [category.ikea_id, *Category.normalize_parent_ids(category.parent_ids)]
    ids.map(&:to_s).reject(&:blank?).uniq.each { |id| Categories::ShowCache.bust!(id) }
  end

  def sync_facet_memberships(category, task, stats)
    attempt = 0
    result = nil

    loop do
      attempt += 1
      result = with_stage_retries(task, category, "facet_memberships") do
        Categories::IkeaFacetMembershipSyncService.new(category.reload).call
      end
      transient_errors = Array(result.errors).select { |error| transient_facet_error?(error) }
      break if transient_errors.empty? || attempt >= STAGE_MAX_ATTEMPTS

      delay = STAGE_RETRY_DELAYS.fetch(attempt - 1, STAGE_RETRY_DELAYS.last)
      task.update_payload!(
        "last_retry" => {
          "category_ikea_id" => category.ikea_id.to_s,
          "stage" => "facet_memberships",
          "attempt" => attempt,
          "message" => transient_errors.first.to_h["message"].to_s,
          "retry_in_seconds" => delay
        }
      )
      sleep(delay)
    end

    errors = Array(result.errors)
    record_facet_errors(category, errors, task, stats) if errors.any?
    result
  rescue StandardError => e
    error = {
      "parameter" => nil,
      "value_id" => nil,
      "error_class" => e.class.name,
      "message" => e.message.to_s
    }
    record_facet_errors(category, [error], task, stats)
    Categories::IkeaFacetMembershipSyncService::Result.new(
      filters_count: 0,
      values_count: 0,
      memberships_count: 0,
      unmatched_skus: [],
      errors: [error]
    )
  end

  def transient_facet_error?(error)
    data = error.to_h.with_indifferent_access
    transient_error?(StandardError.new("#{data[:error_class]}: #{data[:message]}"))
  end

  def record_facet_errors(category, errors, task, stats)
    stats[:facet_errors][category.ikea_id] = errors
    persist_checkpoint!(task, stats, current_category: category, stage: "facet_memberships_with_errors")
  end

  def finish_task(task, stats)
    remaining = incomplete_category_ids(stats)

    if stats[:errors].positive? || remaining.any?
      task.update_columns(
        processed: stats[:processed],
        updated: stats[:updated],
        error_count: stats[:errors]
      )
      message = if stats[:errors].positive?
                  "Актуализация завершена с ошибками: #{stats[:errors]}"
                else
                  "Актуализация не завершена, осталось категорий: #{remaining.size}"
                end
      task.mark_as_failed!(message)
    else
      task.mark_as_completed!(stats)
    end
  end

  def categories_scope(ikea_id)
    return Category.not_deleted.where.not(ikea_id: [nil, ""]).order(:ikea_id) if ikea_id.blank?

    category = Category.not_deleted.find_by(ikea_id: ikea_id.to_s)
    raise ActiveRecord::RecordNotFound, "Категория не найдена или удалена: #{ikea_id}" unless category

    Category.not_deleted.where(ikea_id: category.self_and_descendant_ikea_ids)
  end

  def product_quality_issues(category)
    issues = {
      "missing_delivery_metrics" => [],
      "invalid_sale_price" => [],
      "untranslated_polish_text" => []
    }

    Product.catalog_category_scope(category.ikea_id).find_each do |product|
      metrics = Delivery::ParcelPackingService.export_parcel_metrics(product)
      values = metrics.values_at(:weight_kg, :width_cm, :height_cm, :depth_cm)
      issues["missing_delivery_metrics"] << product.sku.to_s if values.any? { |value| value.to_f <= 0 }
      unless Products::StockAvailability.sale_price?(product.price)
        issues["invalid_sale_price"] << product.sku.to_s
      end

      translated_fields = [product.small_desc_name, product.materials, product.care_instructions]
      if translated_fields.compact.any? { |text| TranslationService.needs_polish_to_russian_translation?(text) }
        issues["untranslated_polish_text"] << product.sku.to_s
      end
    end

    issues.transform_values { |skus| skus.uniq.first(200) }
  end
end
