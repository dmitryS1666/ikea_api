# frozen_string_literal: true

class PolandTrackExport < ApplicationRecord
  belongs_to :order
  encrypts :payload_json

  STATES = %w[pending blocked sending succeeded uncertain cancelled].freeze
  # Local validation failures that can be healed without ShopByShop reconciliation.
  HEALABLE_BLOCK_ERROR = /
    PLN\ssnapshot|
    items\[\d+\]\.link|
    items:\sempty|
    weight:\s
  /x
  validates :state, inclusion: { in: STATES }
  scope :due, -> { where(state: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current) }

  def self.enabled?
    ENV.fetch("POLAND_TRACKS_ENABLED", "false").casecmp?("true")
  end

  def self.supported?(order)
    [DeliveryTypeNormalizer::EUROPOST_PICKUP, DeliveryTypeNormalizer::COURIER, DeliveryTypeNormalizer::IKEYA_DELIVERY]
      .include?(DeliveryTypeNormalizer.normalize(order.delivery_type))
  end

  # Called inside the payment transaction: Redis downtime cannot lose the intent.
  def self.capture_paid!(order)
    return unless enabled? && supported?(order) && !order.checkout_draft?
    return if exists?(order_id: order.id)

    snapshot = PolandTracks::Payload.snapshot(order)
    create!(order: order, payload_json: JSON.generate(snapshot))
  rescue PolandTracks::Payload::Invalid => e
    create!(order: order, state: "blocked", last_error: e.message)
  rescue ActiveRecord::Encryption::Errors::Decryption
    create!(order: order, state: "blocked", last_error: "Cannot decrypt passport")
  end

  def self.enqueue_safely(order_id)
    return unless enabled?

    id = where(order_id: order_id, state: "pending").pick(:id)
    PolandTrackExportJob.perform_later(id) if id
  rescue StandardError => e
    # Never expose exception messages containing request data or credentials.
    Rails.logger.error("[PolandTracks] enqueue failed order=#{order_id} error=#{e.class}")
  end

  # Re-open blocked exports whose missing PLN/URL/weight can now be healed from catalog/order.
  # Skips rows that still cannot build a valid snapshot to avoid a retry loop every minute.
  def self.requeue_healable_blocked!
    return unless enabled?

    where(state: "blocked").find_each do |export|
      export.requeue_if_healable!
    end
  end

  # Only rejected / locally invalid requests may be retried without reconciliation.
  def retry_blocked!
    with_lock do
      raise ArgumentError, "Only blocked exports can be retried" unless state == "blocked"
      update!(state: "pending", payload_json: JSON.generate(PolandTracks::Payload.snapshot(order.reload)),
              next_attempt_at: nil, last_error: nil)
    end
    self.class.enqueue_safely(order_id)
  end

  def requeue_if_healable!
    snapshot = nil
    with_lock do
      return false unless state == "blocked"
      return false unless last_error.to_s.match?(HEALABLE_BLOCK_ERROR)

      order.order_items.order(:id).each { |item| item.ensure_poland_snapshot! }
      order.reload
      begin
        snapshot = PolandTracks::Payload.snapshot(order)
        # Type 1/4 may still wait for Europost; allow missing track while deciding healability.
        PolandTracks::Payload.validate!(
          snapshot,
          allow_missing_track: PolandTracks::Payload.delivery_type(order) != 5
        )
      rescue PolandTracks::Payload::Invalid => e
        update!(last_error: e.message) if last_error != e.message
        return false
      end

      update!(state: "pending", payload_json: JSON.generate(snapshot),
              next_attempt_at: nil, last_error: nil)
    end
    self.class.enqueue_safely(order_id)
    true
  rescue StandardError => e
    Rails.logger.error("[PolandTracks] heal requeue failed export=#{id} error=#{e.class}")
    false
  end
end
