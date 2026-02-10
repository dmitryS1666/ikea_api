Trestle.resource(:pickup_points, model: PickupPoint) do
  menu do
    item :pickup_points, icon: "fa fa-map-marker", label: "Пункты выдачи", group: "Delivery"
  end

  table do
    column :provider, link: true
    column :name
    column :city
    column :address
    column :priority do |p|
      status_tag(p.priority ? 'Да' : 'Нет', p.priority ? :info : :secondary)
    end
    column :active do |p|
      status_tag(p.active ? 'Да' : 'Нет', p.active ? :success : :secondary)
    end
    column :updated_at
    actions
  end

  form do |p|
    select :provider, PickupPoint::PROVIDERS.map { |x| [x, x] }
    text_field :name
    text_field :city
    text_field :address
    text_field :phone
    text_field :working_hours
    text_field :lat
    text_field :lon
    check_box :priority
    check_box :active
    number_field :max_weight_kg, step: 0.001
    number_field :max_volume_m3, step: 0.000001
  end
end
