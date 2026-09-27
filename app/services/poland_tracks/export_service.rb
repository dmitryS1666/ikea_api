# frozen_string_literal: true

module PolandTracks
  class ExportService
    def self.call(export)
      new(export).call
    end

    def initialize(export)
      @export = export
    end

    def call
      return unless PolandTrackExport.enabled?

      payload = nil
      # Commit 'sending' BEFORE HTTP. A killed worker can never cause an automatic
      # second POST. Concurrent workers see 'sending' and do nothing.
      @export.with_lock do
        return unless @export.state == "pending"
        order = @export.order.reload
        if order.status.in?(%w[created processing confirmed cancelled]) || order.checkout_draft? ||
           order.finance_entry&.payment_status == "refunded" || !PolandTrackExport.supported?(order)
          @export.update!(state: "cancelled", last_error: "Order is unpaid, cancelled, refunded, draft or unsupported")
          return
        end
        begin
          snapshot = JSON.parse(@export.payload_json.presence || "{}")
          raise Payload::Invalid, "payload: invalid snapshot structure" unless snapshot.is_a?(Hash)
          if snapshot["delivery_type"] != Payload.delivery_type(order)
            @export.update!(state: "blocked", last_error: "Delivery type changed after payment; review and retry")
            return
          end
          if Payload.delivery_type(order) != 5 && order.resolved_track_number.blank?
            @export.update!(next_attempt_at: 1.minute.from_now, last_error: "Waiting for Europost track")
            return
          end
          Client.validate_config!
          payload = Payload.for_export(@export)
        rescue Payload::Invalid, Client::ConfigurationError, ActiveRecord::Encryption::Errors::Decryption, JSON::ParserError => e
          message = case e
                    when ActiveRecord::Encryption::Errors::Decryption then "Cannot decrypt snapshot"
                    when JSON::ParserError then "Invalid snapshot JSON"
                    else e.message
                    end
          @export.update!(state: "blocked", last_error: message)
          return
        end
        @export.update!(state: "sending", payload_json: JSON.generate(payload),
                        attempts: @export.attempts + 1, last_attempt_at: Time.current,
                        next_attempt_at: nil, last_error: nil)
      end

      begin
        response = Client.create!(payload)
      rescue Client::Rejected, Client::ConfigurationError => e
        @export.update!(state: "blocked", last_error: e.message)
        return
      rescue Client::Uncertain => e
        @export.update!(state: "uncertain", last_error: e.message)
        return
      end
      @export.update!(state: "succeeded", remote_response: response, last_error: nil)
    end
  end
end
