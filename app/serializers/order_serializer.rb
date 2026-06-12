class OrderSerializer
  include FastJsonapi::ObjectSerializer

  # В ЛК не светим числовой id: JSON:API resource id = public_uid (6–8 цифр).
  set_id :public_uid

  attributes :public_uid, :total_amount, :delivery_price, :delivery_type,
             :payment_method, :full_name, :phone, :created_at,
             :payment_expires_at, :payment_url, :webpay_transaction_id, :webpay_paid_at,
             :checkout_draft

  attribute :status do |order|
    order.frontend_status
  end

  attribute :track_number do |order|
    order.customer_track_number
  end

  attribute :payment_expired do |order|
    order.payment_expired?
  end

  attribute :address do |order|
    order.address_json
  end

  attribute :tracking_info do |order|
    order.customer_tracking_info
  end

  attribute :status_timeline do |order|
    order.status_timeline
  end

  attribute :status_description do |order|
    order.frontend_status_title
  end

  has_many :order_items
end
