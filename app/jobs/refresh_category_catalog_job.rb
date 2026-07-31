# frozen_string_literal: true

# Полная актуализация одной категории или всего опубликованного каталога:
# товары и русские атрибуты -> фасеты IKEA -> точные связи SKU/фасет -> cache bust.
class RefreshCategoryCatalogJob < ApplicationJob
  queue_as :parser

  TASK_TYPE = "refresh_category_catalog".freeze

  def perform(ikea_id: nil, task_id: nil, threads: 2)
    task = task_id.present? ? ParserTask.find(task_id) : create_parser_task(TASK_TYPE)
    task.mark_as_running!

    categories = categories_scope(ikea_id)
    stats = {
      processed: 0,
      updated: 0,
      errors: 0,
      products_processed: 0,
      facet_memberships: 0,
      unmatched_skus: {},
      missing_delivery_metrics: {}
    }

    task.update_payload!(
      "ikea_id" => ikea_id.to_s.presence,
      "categories_total" => categories.count,
      "stage" => "started"
    )

    categories.find_each do |category|
      check_task_not_stopped!(task)
      task.update_payload!("current_category_ikea_id" => category.ikea_id, "stage" => "products")

      product_stats = RefreshCategoryFromLtJob.new.perform(
        ikea_id: category.ikea_id,
        task_id: task.id,
        threads: threads,
        manage_task: false
      )

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "filters")
      Categories::LtAvailableFiltersRefreshService.new(
        category,
        reindex: false,
        ensure_series: false
      ).call

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "facet_memberships")
      facet_result = Categories::IkeaFacetMembershipSyncService.new(category.reload).call

      check_task_not_stopped!(task)
      task.update_payload!("stage" => "local_filters")
      Products::FilterValuesIndexer.new(category.reload).reindex!

      # Поиск в проекте работает непосредственно по PostgreSQL и не имеет
      # отдельного Elasticsearch/Searchkick-индекса. После обновления записей
      # достаточно сбросить кеш сериализованной категории.
      Categories::ShowCache.bust!(category.ikea_id)

      missing_delivery_metrics = missing_delivery_metric_skus(category)
      if missing_delivery_metrics.any?
        stats[:missing_delivery_metrics][category.ikea_id] = missing_delivery_metrics.first(200)
      end

      stats[:processed] += 1
      stats[:updated] += 1
      stats[:products_processed] += product_stats.to_h[:processed].to_i
      stats[:facet_memberships] += facet_result.memberships_count.to_i
      if facet_result.unmatched_skus.present?
        stats[:unmatched_skus][category.ikea_id] = facet_result.unmatched_skus.first(200)
      end

      task.update_columns(processed: stats[:processed], updated: stats[:updated])
    rescue StandardError => e
      raise if e.message == "Task was stopped manually"

      stats[:errors] += 1
      task.increment_errors!
      Rails.logger.error(
        "RefreshCategoryCatalogJob category=#{category.ikea_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
    end

    task.update_payload!(
      "stage" => "completed",
      "products_processed" => stats[:products_processed],
      "facet_memberships" => stats[:facet_memberships],
      "unmatched_skus" => stats[:unmatched_skus],
      "missing_delivery_metrics" => stats[:missing_delivery_metrics]
    )
    task.mark_as_completed!(stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    Rails.logger.error("RefreshCategoryCatalogJob: #{e.class} #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    raise if task_id.blank?
  end

  private

  def categories_scope(ikea_id)
    return Category.not_deleted.where.not(ikea_id: [nil, ""]).order(:ikea_id) if ikea_id.blank?

    category = Category.not_deleted.find_by(ikea_id: ikea_id.to_s)
    raise ActiveRecord::RecordNotFound, "Категория не найдена или удалена: #{ikea_id}" unless category

    Category.where(ikea_id: category.ikea_id)
  end

  def missing_delivery_metric_skus(category)
    Product.catalog_category_scope(category.ikea_id).filter_map do |product|
      metrics = Delivery::ParcelPackingService.export_parcel_metrics(product)
      values = metrics.values_at(:weight_kg, :width_cm, :height_cm, :depth_cm)
      product.sku.to_s if values.any? { |value| value.to_f <= 0 }
    end
  end
end
