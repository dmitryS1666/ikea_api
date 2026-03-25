# frozen_string_literal: true

class DownloadProductImagesJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 100

  def perform(limit: nil, product_id: nil, sku: nil, images_limit: nil, task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("product_images", limit: limit)

    stats = {
      processed: 0,
      updated: 0,
      skipped: 0,
      errors: 0
    }

    start_time = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!
      notify_started("product_images", limit: limit)

      products = build_products_scope(limit: limit, product_id: product_id, sku: sku)

      products.find_each(batch_size: BATCH_SIZE) do |product|
        check_task_not_stopped!(task)

        begin
          result = ImageDownloader.sync_product_images(product, limit: images_limit)

          if result[:changed]
            stats[:updated] += 1
            task.increment_updated!
          else
            stats[:skipped] += 1
          end

          stats[:processed] += 1
          task.increment_processed!
        rescue StandardError => e
          Rails.logger.error(
            "DownloadProductImagesJob: error for product id=#{product.id} sku=#{product.sku}: #{e.class} - #{e.message}"
          )
          Rails.logger.error(e.backtrace.first(10).join("\n")) if e.backtrace.present?

          stats[:errors] += 1
          task.increment_errors!
        end
      end

      stats[:duration] = Time.current - start_time
      task.mark_as_completed!(stats)
      notify_completed("product_images", stats)
    rescue TaskStoppedError
      Rails.logger.info("DownloadProductImagesJob: task #{task.id} was stopped manually")
      return
    rescue StandardError => e
      Rails.logger.error("DownloadProductImagesJob fatal error: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace.present?

      task.mark_as_failed!(e.message)
      notify_error("product_images", e)
      raise
    end
  end

  private

  def build_products_scope(limit:, product_id:, sku:)
    scope =
      if product_id.present?
        Product.where(id: product_id)
      elsif sku.present?
        Product.where(sku: sku)
      else
        Product.where.not(images: nil)
               .where("images != '[]' AND images != '' AND images != 'null'")
      end

    scope = scope.limit(limit) if limit.present? && product_id.blank? && sku.blank?
    scope
  end
end
