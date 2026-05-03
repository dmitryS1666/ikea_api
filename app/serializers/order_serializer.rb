class OrderSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :status, :total_amount, :delivery_price, :delivery_type,
             :payment_method, :full_name, :phone, :track_number, :created_at,
             :payment_expires_at, :payment_url, :webpay_transaction_id, :webpay_paid_at,
             :checkout_draft

  attribute :payment_expired do |order|
    order.payment_expired?
  end

  attribute :address do |order|
    order.address_json
  end

  attribute :tracking_info do |order|
    order.tracking_info
  end

  attribute :status_timeline do |order|
    order.status_timeline
  end

  attribute :status_description do |order|
    I18n.t(
      "activerecord.attributes.order.statuses.#{order.status}",
      default: order.status.to_s.humanize
    )
  end

  has_many :order_items
end
