namespace :poland_tracks do
  desc "Dry-run September 2026 paid orders in the last 21 days. RUN=true enqueues exports. AS_OF fixes the window."
  task backfill_september: :environment do
    run = ENV.fetch("RUN", "false")
    abort "RUN must be true or false" unless %w[true false].include?(run)
    report = BackfillPolandTrackExportsJob.perform_now(
      as_of: ENV["AS_OF"].presence || Time.current.iso8601,
      dry_run: run != "true",
      limit: ENV["LIMIT"].presence
    )
    puts JSON.pretty_generate(report)
  end
end
