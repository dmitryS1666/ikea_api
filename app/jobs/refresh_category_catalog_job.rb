# frozen_string_literal: true

# Полная актуализация одной категории или всего опубликованного каталога:
# товары и русские атрибуты -> фасеты IKEA -> точные связи SKU/фасет -> cache bust.
class RefreshCategoryCatalogJob < ApplicationJob
  queue_as :parser

  TASK_TYPE = "refresh_category_catalog".freeze

  def perform(ikea_id: nil, task_id: nil, threads: 2)
    task = task_id.present? ? ParserTask.find(task_id) : create_parser_task(TASK_TYPE)
    task.mark_as_running!

    categories = categories_scope(ikea_id).to_a.sort_by do |category|
      -Category.normalize_parent_ids(category.parent_ids).size
    end
    stats = {
      processed: 0,
      updated: 0,
      errors: 0,
      products_processed: 0,
      facet_memberships: 0,
      unmatched_skus: {},
      missing_delivery_metrics: {},
      facet_errors: {},
      category_errors: {}
    }

    task.update_payload!(
      "ikea_id" => ikea_id.to_s.presence,
      "categories_total" => categories.count,
      "stage" => "started"
    )

    categories.each do |category|
      check_task_not_stopped!(task)
      task.update_payload!("current_category_ikea_id" => category.ikea_id, "stage" => "products")

      product_stats = RefreshCategoryFromLtJob.new.perform(
        ikea_id: category.ikea_id,
        task_id: task.id,
        threads: threads,
        manage_task: false
      )
      stats[:products_processed] += product_stats.to_h.with_indifferent_access[:processed].to_i
      task.update_payload!("products_processed" => stats[:products_processed])

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "filters")
      Categories::LtAvailableFiltersRefreshService.new(
        category,
        reindex: false,
        ensure_series: false
      ).call

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "facet_memberships")
      facet_result = sync_facet_memberships(category, task, stats)
      stats[:facet_memberships] += facet_result.memberships_count.to_i
      if facet_result.unmatched_skus.present?
        stats[:unmatched_skus][category.ikea_id] = facet_result.unmatched_skus.first(200)
      end
      task.update_payload!(
        "facet_memberships" => stats[:facet_memberships],
        "unmatched_skus" => stats[:unmatched_skus]
      )

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "local_filters")
      Products::FilterValuesIndexer.new(category.reload).reindex!

      # Поиск в проекте работает непосредственно по PostgreSQL и не имеет
      # отдельного Elasticsearch/Searchkick-индекса. После обновления записей
      # достаточно сбросить кеш сериализованной категории.
      bust_catalog_tree_cache!(category)

      missing_delivery_metrics = missing_delivery_metric_skus(category)
      if missing_delivery_metrics.any?
        stats[:missing_delivery_metrics][category.ikea_id] = missing_delivery_metrics.first(200)
      end

      stats[:processed] += 1
      stats[:updated] += 1

      task.update_columns(processed: stats[:processed], updated: stats[:updated])
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"

      stats[:errors] += 1
      task.increment_errors!
      stats[:category_errors][category.ikea_id] = {
        "error_class" => e.class.name,
        "message" => e.message.to_s
      }
      task.update_payload!(
        "products_processed" => stats[:products_processed],
        "facet_memberships" => stats[:facet_memberships],
        "facet_errors" => stats[:facet_errors],
        "category_errors" => stats[:category_errors]
      )
      Rails.logger.error(
        "RefreshCategoryCatalogJob category=#{category.ikea_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
    end

    finalize_hierarchical_filters!(categories, task, stats)

    task.update_payload!(
      "stage" => stats[:errors].positive? ? "completed_with_errors" : "completed",
      "products_processed" => stats[:products_processed],
      "facet_memberships" => stats[:facet_memberships],
      "unmatched_skus" => stats[:unmatched_skus],
      "missing_delivery_metrics" => stats[:missing_delivery_metrics],
      "facet_errors" => stats[:facet_errors],
      "category_errors" => stats[:category_errors]
    )
    finish_task(task, stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    Rails.logger.error("RefreshCategoryCatalogJob: #{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    raise if task_id.blank?
  end

  private

  # Дочерние категории обновляются раньше родителей. После полного прохода
  # пересобираем available_filters всех родительских узлов и локальный индекс:
  # товары потомков могли измениться уже после первого reindex родителя.
  def finalize_hierarchical_filters!(categories, task, stats)
    category_ids = categories.map { |category| category.ikea_id.to_s }

    categories.each do |category|
      descendant_ids = category.descendant_ikea_ids & category_ids
      next if descendant_ids.empty?

      check_task_not_stopped!(task)
      task.update_payload!(
        "current_category_ikea_id" => category.ikea_id,
        "stage" => "merge_hierarchical_filters"
      )

      Categories::MergeDescendantAvailableFiltersService.new(category.reload).call
      Products::FilterValuesIndexer.new(category.reload).reindex!
      bust_catalog_tree_cache!(category)
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"

      stats[:errors] += 1
      task.increment_errors!
      stats[:category_errors][category.ikea_id] = {
        "error_class" => e.class.name,
        "message" => e.message.to_s,
        "stage" => "merge_hierarchical_filters"
      }
      task.update_payload!("category_errors" => stats[:category_errors])
      Rails.logger.error(
        "RefreshCategoryCatalogJob hierarchical filters category=#{category.ikea_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
    end
  end

  def bust_catalog_tree_cache!(category)
    ids = [category.ikea_id, *Category.normalize_parent_ids(category.parent_ids)]
    ids.map(&:to_s).reject(&:blank?).uniq.each { |id| Categories::ShowCache.bust!(id) }
  end

  def sync_facet_memberships(category, task, stats)
    result = Categories::IkeaFacetMembershipSyncService.new(category.reload).call
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

  def record_facet_errors(category, errors, task, stats)
    stats[:facet_errors][category.ikea_id] = errors
    stats[:errors] += errors.size
    errors.size.times { task.increment_errors! }
    task.update_payload!("facet_errors" => stats[:facet_errors])
  end

  def finish_task(task, stats)
    if stats[:errors].positive?
      task.update_columns(
        processed: stats[:processed],
        updated: stats[:updated],
        error_count: stats[:errors]
      )
      task.mark_as_failed!("Актуализация завершена с ошибками: #{stats[:errors]}")
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

  def missing_delivery_metric_skus(category)
    Product.catalog_category_scope(category.ikea_id).filter_map do |product|
      metrics = Delivery::ParcelPackingService.export_parcel_metrics(product)
      values = metrics.values_at(:weight_kg, :width_cm, :height_cm, :depth_cm)
      product.sku.to_s if values.any? { |value| value.to_f <= 0 }
    end
  end
end
