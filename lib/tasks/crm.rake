# frozen_string_literal: true

namespace :crm do
  desc "Resync non-draft orders that never received AmoCRM lead id"
  task resync_missing_orders: :environment do
    results = CrmIntegrationService.resync_missing_orders
    ok = results.count { |row| row[:success] }
    failed = results.reject { |row| row[:success] }

    puts "resynced=#{results.size} ok=#{ok} failed=#{failed.size}"
    failed.each do |row|
      puts "FAIL order_id=#{row[:order_id]} public_uid=#{row[:public_uid]} error=#{row[:error].to_s[0, 200]}"
    end
  end
end
