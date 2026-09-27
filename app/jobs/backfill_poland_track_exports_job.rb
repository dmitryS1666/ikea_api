# frozen_string_literal: true

class BackfillPolandTrackExportsJob < ApplicationJob
  queue_as :default

  # Explicit as_of keeps the 21-day interval unchanged across Sidekiq retries.
  # Default is read-only. No schedule is registered for this one-off job.
  def perform(as_of:, dry_run: true, limit: nil)
    report = PolandTracks::SeptemberBackfill.call(as_of: as_of, dry_run: dry_run, limit: limit)
    Rails.logger.info("[PolandBackfillSummary] #{report.except(:details).to_json}")
    report
  end
end
