class UserPickupPointSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :pickup_point_id, :provider, :external_id, :city, :address,
             :working_hours, :lat, :lng, :raw_payload, :created_at, :updated_at
end
