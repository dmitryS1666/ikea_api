# frozen_string_literal: true

namespace :emails do
  desc "Dry-run review-request emails for completed orders. RUN=true enqueues. LIMIT=N optional."
  task backfill_order_delivered_review: :environment do
    run = ENV.fetch("RUN", "false")
    abort "RUN must be true or false" unless %w[true false].include?(run)

    result = OrderDeliveredReviewEmails::BackfillService.call(
      dry_run: run != "true",
      limit: ENV["LIMIT"].presence
    )

    puts JSON.pretty_generate(result.to_h)
  end
end
