namespace :poland_tracks do
  desc "Show export status without passport data: poland_tracks:status[ORDER_DATABASE_ID]"
  task :status, [:order_id] => :environment do |_task, args|
    export = PolandTrackExport.find_by!(order_id: (args[:order_id].presence || abort("Order database ID is required")))
    puts export.attributes.slice("id", "order_id", "state", "attempts", "last_error", "remote_response", "last_attempt_at").to_json
  end

  desc "Retry blocked export after correcting profile/config: poland_tracks:retry[ORDER_DATABASE_ID]"
  task :retry, [:order_id] => :environment do |_task, args|
    PolandTrackExport.find_by!(order_id: (args[:order_id].presence || abort("Order database ID is required"))).retry_blocked!
    puts "Queued"
  end

  desc "Recover pending exports (also runs every minute via CronSchedule)"
  task dispatch: :environment do
    DispatchPolandTrackExportsJob.perform_now
  end

  desc "Heal blocked exports missing PLN/URL/weight from catalog and requeue: poland_tracks:heal_blocked"
  task heal_blocked: :environment do
    before = PolandTrackExport.where(state: "blocked").count
    PolandTrackExport.requeue_healable_blocked!
    after = PolandTrackExport.where(state: "blocked").count
    puts({ blocked_before: before, blocked_after: after, requeued: before - after }.to_json)
  end

  desc "After remote reconciliation only: resolve uncertain export as absent; CONFIRMED_ABSENT=yes required"
  task :resolve_absent, [:order_id] => :environment do |_task, args|
    abort "First verify in ShopByShop that this order has NO track; then set CONFIRMED_ABSENT=yes" unless ENV["CONFIRMED_ABSENT"] == "yes"
    export = PolandTrackExport.find_by!(order_id: (args[:order_id].presence || abort("Order database ID is required")))
    export.with_lock do
      raise "Only uncertain exports can be resolved" unless export.state == "uncertain"
      # Reuse the exact original snapshot. Do not silently replace recipient or prices.
      export.update!(state: "pending", last_error: nil, next_attempt_at: nil)
    end
    PolandTrackExport.enqueue_safely(export.order_id)
    puts "Queued after confirmed remote absence"
  end

  desc "Resolve uncertain export as created using RESPONSE_FILE with the API response JSON"
  task :resolve_created, [:order_id] => :environment do |_task, args|
    response = JSON.parse(File.read(ENV.fetch("RESPONSE_FILE")))
    export = PolandTrackExport.find_by!(order_id: (args[:order_id].presence || abort("Order database ID is required")))
    export.with_lock do
      raise "Only uncertain exports can be resolved" unless export.state == "uncertain"
      PolandTracks::Client.validate_response!(response, JSON.parse(export.payload_json))
      export.update!(state: "succeeded", remote_response: response.slice(*PolandTracks::Client::RESPONSE_KEYS), last_error: nil)
    end
    puts "Marked as created; no POST was made"
  end
end
