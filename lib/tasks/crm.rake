# frozen_string_literal: true

namespace :crm do
  desc "Resync non-draft orders that never received AmoCRM lead id"
  task resync_missing_orders: :environment do
    print_resync_results(CrmIntegrationService.resync_missing_orders)
  end

  desc "Resync orders into AmoCRM. SINCE=2026-09-01 UNTIL=2026-10-01 LIMIT=50"
  task resync_orders: :environment do
    since = ENV["SINCE"].presence&.then { |value| Time.zone.parse(value) }
    until_time = ENV["UNTIL"].presence&.then { |value| Time.zone.parse(value) }
    limit = ENV["LIMIT"].presence&.to_i
    only_missing = ActiveModel::Type::Boolean.new.cast(ENV["ONLY_MISSING"])

    results = CrmIntegrationService.resync_orders(
      since: since,
      until_time: until_time,
      only_missing: only_missing,
      limit: limit
    )
    print_resync_results(results)
  end
end

def print_resync_results(results)
  ok = results.count { |row| row[:success] }
  failed = results.reject { |row| row[:success] }

  puts "resynced=#{results.size} ok=#{ok} failed=#{failed.size}"
  failed.each do |row|
    puts "FAIL order_id=#{row[:order_id]} public_uid=#{row[:public_uid]} error=#{row[:error].to_s[0, 200]}"
  end
end
