# frozen_string_literal: true

# Freezes every value used by transactional order emails. Status emails may be
# sent days or weeks after checkout, so they must not depend on mutable product
# cards, exchange rates, promo rules or customs settings.
class OrderEmailSnapshotService
  VERSION = 1
  REQUIRED_KEYS = %w[
    version
    items_count
    items_total_byn
    delivery_total_byn
    discount_total_byn
    grand_total_byn
    customs_total_byn
  ].freeze

  class << self
    def capture!(order, pricing: nil, force: false)
      raise ArgumentError, "order must be persisted" unless order&.persisted?

      order.with_lock do
        order.reload
        capture_item_content!(order, force: force)

        if force || !complete?(order.pricing_snapshot)
          calculated_pricing = pricing || CartPricingService.call_from_order(order: order)
          order.update_columns(pricing_snapshot: build(order, calculated_pricing))
        end
      end

      order.reload
    end

    def complete?(snapshot)
      data = snapshot.is_a?(Hash) ? snapshot.stringify_keys : {}
      REQUIRED_KEYS.all? { |key| data.key?(key) } && data["version"].to_i == VERSION
    end

    private

    def capture_item_content!(order, force:)
      order.order_items.includes(:product).find_each do |item|
        item.capture_email_snapshot!(force: force)
      end
    end

    def build(order, pricing)
      totals = (pricing || {}).with_indifferent_access[:totals] || {}

      {
        "version" => VERSION,
        "captured_at" => Time.current.iso8601,
        "items_count" => order.order_items.sum(:quantity).to_i,
        "items_total_byn" => money(order.order_items.sum { |item| item.price.to_f * item.quantity.to_i }),
        "delivery_total_byn" => money(order.delivery_price),
        "discount_total_byn" => money(order.discount_amount),
        "grand_total_byn" => money(order.total_amount),
        "customs_total_byn" => money(totals[:customs_total_byn]),
        "promo_code" => order.promo_code&.code
      }
    end

    def money(value)
      format("%.2f", value.to_f)
    end
  end
end
