class OptimizeHomeBannerImagesJob < ApplicationJob
  queue_as :parser

  def perform(task_id: nil, limit: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("optimize_home_banner_images", limit: limit)
    task.mark_as_running!

    stats = {
      processed: task.processed || 0,
      updated: 0,
      skipped: 0,
      errors: 0
    }

    scope = HomeBanner.with_attached_image
    scope = scope.limit(limit.to_i) if limit.present? && limit.to_i.positive?

    scope.find_each do |banner|
      check_task_not_stopped!(task)
      next unless banner.image.attached?

      optimize_banner_image!(banner, task, stats)
    end

    task.reload
    stats[:processed] = task.processed
    stats[:updated] = task.updated
    stats[:errors] = task.error_count
    task.mark_as_completed!(stats)
    notify_completed("optimize_home_banner_images", stats)

    Rails.logger.info("[OptimizeHomeBannerImagesJob] finished: #{stats.inspect}")
    stats
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    notify_error("optimize_home_banner_images", e)
    raise e
  end

  private

  def optimize_banner_image!(banner, task, stats)
    source_blob = banner.image.blob
    optimized_blob = Images::WebpOptimizer.optimize_blob(source_blob)

    if optimized_blob.id == source_blob.id
      stats[:skipped] += 1
      task.increment_processed!
      return
    end

    banner.image.attach(optimized_blob)
    task.increment_updated!
    task.increment_processed!
    stats[:updated] += 1
  rescue => e
    task.increment_errors!
    task.increment_processed!
    stats[:errors] += 1
    Rails.logger.error(
      "[OptimizeHomeBannerImagesJob] banner_id=#{banner.id} failed: #{e.class} #{e.message}"
    )
  end
end
