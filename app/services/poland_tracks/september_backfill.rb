# frozen_string_literal: true

require "time"

module PolandTracks
  # A one-off backfill, intentionally restricted to September 2026.
  # Does not create shipments or call external APIs; it creates durable exports.
  class SeptemberBackfill
    PAYMENT_TIME_SQL = <<~SQL.squish.freeze
      COALESCE(orders.webpay_paid_at,
        (SELECT MIN(order_status_events.changed_at)
         FROM order_status_events
         WHERE order_status_events.order_id = orders.id
           AND order_status_events.to_status = 'paid'))
    SQL
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
      unless @dry_run
        raise ArgumentError, "Enable POLAND_TRACKS_ENABLED before enqueueing" unless PolandTrackExport.enabled?
        Client.validate_config!
      end
      report = { dry_run: @dry_run, from: @from.iso8601, to_exclusive: @to.iso8601,
                 timezone: "Europe/Minsk", examined: 0, counts: Hash.new(0), details: [], details_truncated: false }
      return report if @from >= @to

      candidates.find_each(batch_size: 100) do |order|
        row = @dry_run ? inspect_order(order) : persist_order(order)
        report[:examined] += 1
        report[:counts][row[:result]] += 1
        public_row = row.except(:snapshot)
        if report[:details].size < DETAILS_LIMIT
          report[:details] << public_row
        else
          report[:details_truncated] = true
        end
        Rails.logger.info("[PolandBackfill] #{public_row.to_json}")
        break if @limit && report[:examined] >= @limit
      end
      report
    end

    private

    def candidates
      Order.where(checkout_draft: false, status: FinanceEntry::PAID_ORDER_STATUSES)
           .where("#{PAYMENT_TIME_SQL} >= ? AND #{PAYMENT_TIME_SQL} < ?", @from, @to)
           .where.not(id: FinanceEntry.where(payment_status: "refunded").select(:order_id))
    end

    def inspect_order(order)
      row = { order_id: order.id, order_number: order.display_number }
      if (existing = PolandTrackExport.find_by(order_id: order.id))
        return row.merge(result: "existing", export_id: existing.id, state: existing.state)
      end
      return row.merge(result: "unsupported_delivery") unless PolandTrackExport.supported?(order)

      snapshot = Payload.snapshot(order)
      draft = PolandTrackExport.new(order: order, payload_json: JSON.generate(snapshot))
      # Validate recipient, prices and delivery address even if Europost is pending.
      Payload.for_export(draft, allow_missing_track: true)
      waiting = Payload.delivery_type(order) != 5 && order.resolved_track_number.blank?
      row.merge(result: waiting ? "waiting_track" : "ready", snapshot: snapshot)
    rescue Payload::Invalid => e
      row.merge(result: "blocked", error: e.message, snapshot: snapshot)
    rescue ActiveRecord::Encryption::Errors::Decryption
      row.merge(result: "blocked", error: "Cannot decrypt passport")
    end

    def persist_order(order)
      row = nil
      order.with_lock do
        # Recheck eligibility after locking: payment/cancellation/refund may have changed.
        unless candidates.where(id: order.id).exists?
          return { order_id: order.id, order_number: order.display_number, result: "no_longer_eligible" }
        end
        row = inspect_order(order)
        if %w[ready waiting_track blocked].include?(row[:result])
          export = PolandTrackExport.create!(
            order: order,
            state: row[:result] == "blocked" ? "blocked" : "pending",
            last_error: row[:error],
            payload_json: row[:snapshot] ? JSON.generate(row[:snapshot]) : nil
          )
          row = row.merge(export_id: export.id)
        end
      end
      if %w[ready waiting_track].include?(row[:result])
        PolandTrackExport.enqueue_safely(order.id)
      end
      row
    end
  end
end
