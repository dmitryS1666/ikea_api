class UserDeliveryAddressSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :city, :street, :house, :building, :apartment,
             :entrance, :floor, :elevator_type, :intercom, :is_private_house,
             :lat, :lng, :comment, :created_at, :updated_at

  attribute :formatted_address do |address|
    address.formatted_address
  end
end
