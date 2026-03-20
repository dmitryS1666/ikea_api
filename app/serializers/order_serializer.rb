class OrderSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :status, :total_amount, :delivery_price, :delivery_type, 
             :payment_method, :full_name, :phone, :track_number, :created_at

  attribute :address do |order|
    order.address_json
  end

  attribute :tracking_info do |order|
    order.tracking_info
  end

  has_many :order_items
end
