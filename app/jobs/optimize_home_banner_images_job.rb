class OptimizeHomeBannerImagesJob < ApplicationJob
  queue_as :default

  def perform
    stats = {
      scanned: 0,
      updated: 0,
      skipped: 0,
      failed: 0
    }

    HomeBanner.with_attached_image.find_each do |banner|
      next unless banner.image.attached?

      stats[:scanned] += 1
      optimize_banner_image!(banner, stats)
    end

    Rails.logger.info("[OptimizeHomeBannerImagesJob] finished: #{stats.inspect}")
    stats
  end

  private

  def optimize_banner_image!(banner, stats)
    source_blob = banner.image.blob
    optimized_blob = Images::WebpOptimizer.optimize_blob(source_blob)

    if optimized_blob.id == source_blob.id
      stats[:skipped] += 1
      return
    end

    banner.image.attach(optimized_blob)
    stats[:updated] += 1
  rescue => e
    stats[:failed] += 1
    Rails.logger.error(
      "[OptimizeHomeBannerImagesJob] banner_id=#{banner.id} failed: #{e.class} #{e.message}"
    )
  end
end
