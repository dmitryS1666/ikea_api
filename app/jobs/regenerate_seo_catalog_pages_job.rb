# frozen_string_literal: true

class RegenerateSeoCatalogPagesJob < ApplicationJob
  queue_as :default

  def perform
    stats = { processed: 0, changed: 0, errors: 0 }

    SeoCatalogPage.published.find_each do |page|
      stats[:processed] += 1

      result = SeoCatalogPages::GenerateSnapshotService.call(page)
      stats[:changed] += 1 if result.changed
    rescue StandardError => e
      stats[:errors] += 1
      Rails.logger.error("RegenerateSeoCatalogPagesJob page_id=#{page&.id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    end

    Rails.logger.info("RegenerateSeoCatalogPagesJob finished #{stats.inspect}")
    stats
  end
end
