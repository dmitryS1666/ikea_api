# frozen_string_literal: true

# Перезагружает описательные поля товара с приоритетом LT (русский текст), при отсутствии LT —
# PL + перевод через TranslationService (в т.ч. OpenAI в AiTranslationService).
#
# По умолчанию обрабатывает только товары, которые счётчик помечает как «подозрительные»
# (см. Products::SuspectedPolishInCustomerPayload и CountBrokenProductTranslationsJob).
class RecoverBrokenProductTranslationsJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 50

  def perform(limit: nil, task_id: nil, only_suspected: true, sku: nil, skus: nil, category_ikea_id: nil)
    task =
      if task_id.present?
        ParserTask.find(task_id)
      else
        create_parser_task("recover_broken_product_translations", limit: limit)
      end

    payload_h = (task.payload || {}).stringify_keys

    only_suspected =
      if payload_h.key?("only_suspected")
        ActiveModel::Type::Boolean.new.cast(payload_h["only_suspected"])
      else
        only_suspected
      end

    sku = payload_h["sku"].presence || sku
    skus = payload_h["skus"].presence || skus
    category_ikea_id = payload_h["category_ikea_id"].presence || category_ikea_id

    effective_limit = limit
    effective_limit = task.limit if effective_limit.blank? && task.respond_to?(:limit) && task.limit.present?

    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == "pending"

    stats = {
      processed: 0,
      updated: 0,
      skipped: 0,
      still_suspect: 0,
      errors: 0
    }

    started_at = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!

      query = build_scope(sku: sku, skus: skus, category_ikea_id: category_ikea_id)
      if effective_limit.present? && effective_limit.to_i.positive?
        query = query.limit(effective_limit.to_i)
      end

      total_count = query.count
      task.update_payload!(
        total_to_process: total_count,
        only_suspected: only_suspected,
        sku: sku,
        skus: normalize_skus([sku, skus].compact),
        category_ikea_id: category_ikea_id.to_s.strip.presence
      )

      notify_started("recover_broken_product_translations", limit: total_count)
      Rails.logger.info(
        "RecoverBrokenProductTranslationsJob: #{total_count} products " \
        "(only_suspected=#{only_suspected})"
      )

      query.find_in_batches(batch_size: BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)

        batch.each do |product|
          check_task_not_stopped!(task)

          if only_suspected && !Products::SuspectedPolishInCustomerPayload.suspect?(product)
            stats[:skipped] += 1
            stats[:processed] += 1
            task.increment_processed!
            next
          end

          begin
            Products::ExtendedAttributesFetchService.fetch_for_product(
              product,
              force_ai_translation: true,
              fallback_pl_when_lt_missing: true,
              skip_document_download: true
            )

            product.reload

            if Products::SuspectedPolishInCustomerPayload.suspect?(product)
              stats[:still_suspect] += 1
            else
              stats[:updated] += 1
              task.increment_updated!
            end

            stats[:processed] += 1
            task.increment_processed!
          rescue StandardError => e
            Rails.logger.error "RecoverBrokenProductTranslationsJob sku=#{product.sku}: #{e.message}"
            stats[:errors] += 1
            stats[:processed] += 1
            task.increment_processed!
            task.increment_errors!
          end
        end
      end

      stats[:duration] = Time.current - started_at

      task.update_payload!(
        "fixed_count" => stats[:updated],
        "still_suspect_after" => stats[:still_suspect],
        "skipped_not_suspect" => stats[:skipped],
        "recover_errors" => stats[:errors],
        "duration_seconds" => stats[:duration].to_f
      )

      task.mark_as_completed!(
        processed: stats[:processed],
        updated: stats[:updated],
        errors: stats[:errors]
      )
      notify_completed("recover_broken_product_translations", stats)
    rescue StandardError => e
      return if e.message == "Task was stopped manually"

      task&.mark_as_failed!(e.message)
      notify_error("recover_broken_product_translations", e)
      raise
    end
  end

  private

  def build_scope(sku:, skus:, category_ikea_id:)
    scope = Product.all
    requested_skus = normalize_skus([sku, skus].compact)

    if requested_skus.present?
      aliases = requested_skus.flat_map { |val| Products::ListingSkuResolver.aliases(val) }.map(&:to_s).uniq
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

    scope.order(:id)
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
