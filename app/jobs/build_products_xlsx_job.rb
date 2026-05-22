# frozen_string_literal: true

class BuildProductsXlsxJob < ApplicationJob
  queue_as :default

  def perform(limit: nil)
    Rails.logger.info("[BuildProductsXlsxJob] start limit=#{limit.inspect}")
    path = Admin::ProductsXlsxExportService.build!(limit: limit)
    Rails.logger.info("[BuildProductsXlsxJob] done path=#{path}")
  rescue Admin::ProductsXlsxExportService::AlreadyBuilding
    Rails.logger.warn("[BuildProductsXlsxJob] skipped — export already building")
  rescue StandardError => e
    Rails.logger.error("[BuildProductsXlsxJob] failed #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")
    raise
  end
end
