# frozen_string_literal: true

class RecoverBrokenProductImagesJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 100

  def perform(log_path: nil, limit: nil, sku: nil, images_limit: nil, task_id: nil, sku_file_path: nil)
    log_path ||= find_latest_log_path
    task = task_id ? ParserTask.find(task_id) : create_parser_task("recover_broken_product_images", limit: limit)

    payload = task.payload || {}
    skus_from_payload = payload["skus"]
    sku ||= skus_from_payload if skus_from_payload.present?
    
    # Путь к файлу SKU может быть в payload
    sku_file_path ||= payload["sku_file_path"]

    stats = {
      processed: 0,
      updated: 0,
      skipped: 0,
      errors: 0,
      repaired_images: 0,
      downloaded_images: 0,
      broken_skus_in_log: 0
    }

    started_at = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!
      
      skus = if sku.present?
               sku.is_a?(Array) ? sku : sku.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?)
             elsif sku_file_path.present? && File.exist?(sku_file_path)
               File.readlines(sku_file_path).map(&:strip).reject(&:blank?)
             else
               extract_skus_from_log(log_path)
             end

      # Нормализация SKUs (удаление точек и т.д., если в БД они без точек)
      skus = skus.map { |s| s.to_s.gsub(".", "").strip }.reject(&:blank?)

      if skus.empty?
        error_msg = log_path.present? ? "No SKUs found in log: #{log_path}" : "No SKUs provided and no log files found"
        Rails.logger.warn "RecoverBrokenProductImagesJob: #{error_msg}"
        task.mark_as_failed!(error_msg)
        return
      end

      skus = skus.first(limit) if limit.present?
      stats[:broken_skus_in_log] = skus.size

      notify_started("recover_broken_product_images", limit: stats[:broken_skus_in_log])
      Rails.logger.info "RecoverBrokenProductImagesJob: Starting processing #{skus.size} SKUs"

      # Находим товары и запускаем восстановление
      Product.where(sku: skus).find_each(batch_size: BATCH_SIZE) do |product|
        check_task_not_stopped!(task)

        begin
          result = IkeaLvImageRecoveryService.new(
            product: product,
            images_limit: images_limit
          ).call

          stats[:processed] += 1
          task.increment_processed!

          if result[:changed]
            stats[:updated] += 1
            stats[:repaired_images] += result[:repaired_images].to_i
            stats[:downloaded_images] += result[:downloaded_images].to_i
            task.increment_updated!
          else
            stats[:skipped] += 1
          end
        rescue StandardError => e
          Rails.logger.error(
            "RecoverBrokenProductImagesJob: error for product id=#{product.id} sku=#{product.sku}: #{e.class} - #{e.message}"
          )
          Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace.present?

          stats[:errors] += 1
          task.increment_errors!
        end
      end

      stats[:duration] = Time.current - started_at
      task.mark_as_completed!(stats)
      notify_completed("recover_broken_product_images", stats)
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info("RecoverBrokenProductImagesJob: task #{task.id} was stopped manually")
        return
      end

      Rails.logger.error("RecoverBrokenProductImagesJob fatal error: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace.present?

      task.mark_as_failed!(e.message)
      notify_error("recover_broken_product_images", e)
      raise
    end
  end

  private

  def find_latest_log_path
    log_dir = Rails.root.join("log")
    logs = Dir.glob(log_dir.join("check_broken_local_images_*.log")).sort.reverse
    logs.first
  end

  def extract_skus_from_log(log_path)
    return [] if log_path.blank?
    return [] unless File.exist?(log_path)

    skus = []

    File.foreach(log_path) do |line|
      next unless line.include?("sku=")

      if (match = line.match(/sku=([A-Za-z0-9_-]+)/))
        skus << match[1]
      end
    end

    skus.uniq
  end
end
