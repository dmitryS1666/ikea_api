# frozen_string_literal: true

class GenerateProductImagePreviewsJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 200

  def perform(limit: nil, sku: nil, force: false, task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("generate_product_image_previews", limit: limit, payload: { sku: sku, force: force })

    stats = {
      processed: 0,
      generated: 0,
      skipped: 0,
      errors: 0
    }

    log_file = Rails.root.join("log", "generate_product_image_previews_#{task.id}.log")
    logger = Logger.new(log_file)
    logger.info "Starting GenerateProductImagePreviewsJob task_id=#{task.id} sku=#{sku.inspect} force=#{force} limit=#{limit.inspect}"

    started_at = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!
      notify_started("generate_product_image_previews", limit: limit)

      source_paths = collect_source_paths(sku: sku)
      source_paths = source_paths.first(limit.to_i) if limit.present? && limit.to_i.positive?

      logger.info "Source images to process: #{source_paths.size}"
      stats[:total_to_process] = source_paths.size

      source_paths.each_slice(BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)

        batch.each do |source_path|
          result = Products::GenerateImagePreviewService.new(
            source_path: source_path,
            force: force,
            logger: logger
          ).call

          stats[:processed] += 1
          task.increment_processed!

          if result.error.present?
            stats[:errors] += 1
            task.increment_errors!
          elsif result.generated
            stats[:generated] += 1
            task.increment_updated!
          else
            stats[:skipped] += 1
          end
        end
      end

      stats[:duration] = Time.current - started_at
      task.mark_as_completed!(stats)
      notify_completed("generate_product_image_previews", stats)
      logger.info "Finished. Stats: #{stats.inspect}"
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        logger.info "Job was stopped manually."
        return
      end

      logger.fatal "Fatal error: #{e.class}: #{e.message}"
      task.mark_as_failed!(e.message)
      notify_error("generate_product_image_previews", e)
      raise e
    end
  end

  private

  def collect_source_paths(sku:)
    if sku.present?
      skus = sku.is_a?(Array) ? sku : sku.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?)
      paths = []

      Product.where(sku: skus).find_each do |product|
        ProductLocalImages.expand_paths(product.local_images).each do |rel|
          abs = ProductLocalImages.public_abs_path(rel)
          paths << abs if abs.present? && !ProductLocalImages.preview_path?(rel)
        end
      end

      paths.uniq
    else
      Dir.glob(Rails.public_path.join("images/products/**/*.webp").to_s)
         .reject { |path| ProductLocalImages.preview_path?(path) }
         .select { |path| File.file?(path) && File.size(path).positive? }
         .sort
    end
  end
end
