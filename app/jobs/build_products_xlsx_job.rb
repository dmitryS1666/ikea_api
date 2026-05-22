# frozen_string_literal: true

class BuildProductsXlsxJob < ApplicationJob
  queue_as :default

  def perform(limit: nil)
    Admin::ProductsXlsxExportService.build!(limit: limit)
  rescue Admin::ProductsXlsxExportService::AlreadyBuilding
    Rails.logger.warn("[BuildProductsXlsxJob] skipped — export already building")
  end
end
