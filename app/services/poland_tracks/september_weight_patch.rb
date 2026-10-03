# frozen_string_literal: true

require "time"

module PolandTracks
  # One-off: inject root weight into September 2026 export snapshots that were
  # captured before the field existed. Does not POST again for succeeded rows —
  # ShopByShop create has no update/idempotency path.
  class SeptemberWeightPatch
    PAYMENT_TIME_SQL = SeptemberBackfill::PAYMENT_TIME_SQL
    DETAILS_LIMIT = 500

    def self.call(as_of:, dry_run: true, limit: nil)
      new(as_of: as_of, dry_run: dry_run, limit: limit).call
    end

    def initialize(as_of:, dry_run:, limit:)
      raise ArgumentError, "dry_run must be true or false" unless [true, false].include?(dry_run)
      raise ArgumentError, "as_of must be ISO8601 with an explicit timezone" unless as_of.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      @as_of = Time.iso8601(as_of.to_s).in_time_zone("Europe/Minsk")
      @dry_run = dry_run
      @limit = limit.nil? ? nil : Integer(limit)
      raise ArgumentError, "limit must be positive" if @limit && @limit <= 0
      zone = Time.find_zone!("Europe/Minsk")
      @from = [@as_of - 21.days, zone.local(2026, 9, 1)].max
      @to = [@as_of, zone.local(2026, 10, 1)].min
    end

    def call
      report = { dry_run: @dry_run, from: @from.iso8601, to_exclusive: @to.iso8601,
                 timezone: "Europe/Minsk", examined: 0, counts: Hash.new(0), details: [], details_truncated: false }
      return report if @from >= @to

      exports.find_each(batch_size: 100) do |export|
        row = @dry_run ? inspect_export(export) : persist_export(export)
        report[:examined] += 1
        report[:counts][row[:result]] += 1
        if report[:details].size < DETAILS_LIMIT
          report[:details] << row
        else
          report[:details_truncated] = true
        end
        Rails.logger.info("[PolandWeightPatch] #{row.to_json}")
        break if @limit && report[:examined] >= @limit
      end
      report
    end

    private

    def exports
      PolandTrackExport.joins(:order)
                       .where("#{PAYMENT_TIME_SQL} >= ? AND #{PAYMENT_TIME_SQL} < ?", @from, @to)
                       .order(:id)
    end

    def inspect_export(export)
      row = { order_id: export.order_id, export_id: export.id, state: export.state }
      payload = JSON.parse(export.payload_json.presence || "{}")
      return row.merge(result: "already_has_weight", weight: payload["weight"]) if payload["weight"].present?
      return row.merge(result: "succeeded_remote_immutable") if export.state == "succeeded"
      return row.merge(result: "sending_or_uncertain_skip") if %w[sending uncertain].include?(export.state)
      return row.merge(result: "cancelled_skip") if export.state == "cancelled"

      weight = Payload.new(export.order).weight_grams
      row.merge(result: %w[pending blocked].include?(export.state) ? "ready_to_patch" : "unsupported_state",
                weight: weight)
    rescue Payload::Invalid => e
      row.merge(result: "blocked_missing_weight", error: e.message)
    rescue ActiveRecord::Encryption::Errors::Decryption, JSON::ParserError
      row.merge(result: "blocked_bad_snapshot", error: "Cannot read snapshot")
    end

    def persist_export(export)
      row = nil
      export.with_lock do
        row = inspect_export(export)
        if row[:result] == "ready_to_patch"
          payload = Payload.with_weight(JSON.parse(export.payload_json), row[:weight])
          Payload.validate!(payload, allow_missing_track: true)
          export.update!(payload_json: JSON.generate(payload),
                         last_error: export.state == "blocked" ? nil : export.last_error,
                         state: export.state == "blocked" ? "pending" : export.state,
                         next_attempt_at: nil)
          row = row.merge(result: "patched", state: export.state)
        end
      end
      PolandTrackExport.enqueue_safely(export.order_id) if row[:result] == "patched"
      row
    end
  end
end
