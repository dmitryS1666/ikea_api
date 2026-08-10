# frozen_string_literal: true

# Повторный HTTP-парсинг карточки PL (+ LT при наличии URL) через ExtendedAttributesFetchService,
# чтобы в full_attributes попал measurements_modal и в API — packages / packaging с габаритами.
# Данные measurementGroups уже встроены в hydration HTML, поэтому Chrome для этой задачи не нужен.
# Галерею с PL не сверяем (skip_image_reconciliation), чтобы задача не меняла images/local_images.
class RecoverMissingPackagingDimensionsJob < ApplicationJob
  queue_as :parser

  def perform(
    limit: nil,
    task_id: nil,
    only_missing_packaging_dimensions: true,
    packaging_recover_sku: nil,
    packaging_recover_skus: nil,
    category_ikea_id: nil
  )
    task = task_id ? ParserTask.find(task_id) : create_parser_task("recover_missing_packaging_dimensions", limit: limit)

    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == "pending"

    stats = {
      processed: 0,
      updated: 0,
      recovered: 0,
      skipped: 0,
      fetch_skipped: 0,
      errors: 0
    }

    started_at = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!

      query = build_scope(
        sku: packaging_recover_sku,
        skus: packaging_recover_skus,
        category_ikea_id: category_ikea_id
      )
      query = query.limit(limit) if limit.present?

      total_count = query.count
      task.update_payload!(
        total_to_process: total_count,
        only_missing_packaging_dimensions: only_missing_packaging_dimensions,
        packaging_recover_sku: packaging_recover_sku.to_s.strip.presence,
        packaging_recover_skus: normalize_skus(packaging_recover_skus),
        category_ikea_id: category_ikea_id.to_s.strip.presence
      )

      notify_started("recover_missing_packaging_dimensions", limit: total_count)
      Rails.logger.info(
        "RecoverMissingPackagingDimensionsJob: #{total_count} products " \
        "(only_missing=#{only_missing_packaging_dimensions})"
      )

      query.find_each(batch_size: 100) do |product|
        check_task_not_stopped!(task)

        begin
          if product.url.blank?
            stats[:skipped] += 1
            stats[:processed] += 1
            task.increment_processed!
            next
          end

          before_missing = Products::PackagingDimensionsStatus.missing_full_packaging_dimensions?(product)

          if only_missing_packaging_dimensions && !before_missing
            stats[:skipped] += 1
            stats[:processed] += 1
            task.increment_processed!
            next
          end

          result =
            Products::ExtendedAttributesFetchService.fetch_for_product(
              product,
              fallback_pl_when_lt_missing: true,
              skip_document_download: true,
              skip_image_reconciliation: true,
              allow_headless: false
            )

          if result[:skipped_missing_lt]
            stats[:fetch_skipped] += 1
          end

          product.reload

          if result[:updated]
            stats[:updated] += 1
            task.increment_updated!
          end

          after_ok = Products::PackagingDimensionsStatus.full_packaging_dimensions_in_customer_payload?(product)
          stats[:recovered] += 1 if before_missing && after_ok

          stats[:processed] += 1
          task.increment_processed!
        rescue StandardError => e
          Rails.logger.error(
            "RecoverMissingPackagingDimensionsJob sku=#{product.sku}: #{e.class} #{e.message}\n" \
            "#{e.backtrace.first(8).join("\n")}"
          )
          stats[:errors] += 1
          task.increment_errors!
          stats[:processed] += 1
          task.increment_processed!
        end
      end

      stats[:duration] = Time.current - started_at
      Rails.logger.info(
        "RecoverMissingPackagingDimensionsJob completed: #{stats.slice(:processed, :updated, :recovered, :skipped, :fetch_skipped, :errors).inspect}"
      )
      task.mark_as_completed!(stats)
      notify_completed("recover_missing_packaging_dimensions", stats)
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        Rails.logger.info("RecoverMissingPackagingDimensionsJob: task #{task.id} stopped manually")
        return
      end

      Rails.logger.error("RecoverMissingPackagingDimensionsJob fatal: #{e.class} #{e.message}")
      task.mark_as_failed!(e.message)
      notify_error("recover_missing_packaging_dimensions", e)
      raise
    end
  end

  private

  def build_scope(sku:, skus:, category_ikea_id:)
    # Фильтр «нет полной тройки размеров упаковки» — в цикле (виртуальный customer payload).
    scope = Product.where.not(url: [nil, ""])

    requested = normalize_skus([sku, skus].compact)
    if requested.present?
      aliases = requested.flat_map { |val| Products::ListingSkuResolver.aliases(val) }.map(&:to_s).uniq
      scope = scope.where(sku: aliases)
    end

    cid = category_ikea_id.to_s.strip.presence
    if cid.present?
      scope =
        scope
          .left_joins(:category_products)
          .where("products.category_id = :cid OR category_products.category_id = :cid", cid: cid)
          .distinct
    end

    scope
  end

  def normalize_skus(raw)
    return [] if raw.blank?

    values =
      case raw
      when String
        raw.split(/[\s,;\n\r\t]+/)
      when Array
        raw.flat_map { |v| v.to_s.split(/[\s,;\n\r\t]+/) }
      else
        [raw.to_s]
      end

    values.map { |v| v.to_s.strip }.reject(&:blank?).uniq
  end
end
