Trestle.resource(:pickup_points, model: PickupPoint) do
  menu do
    item :pickup_points, icon: "fa fa-map-marker", label: "Пункты выдачи", group: "Доставка"
  end

  table do
    column :provider, link: true do |p|
      I18n.t("activerecord.attributes.pickup_point.providers.#{p.provider}", default: p.provider)
    end
    column :name
    column :city
    column :address
    column :priority do |p|
      status_tag(p.priority ? 'Да' : 'Нет', p.priority ? :info : :secondary)
    end
    column :active do |p|
      status_tag(p.active ? 'Да' : 'Нет', p.active ? :success : :secondary)
    end
    column :updated_at, align: :center
    actions
  end

  form do |p|
    tab :basic, label: "Основное" do
      select :provider, PickupPoint::PROVIDERS.map { |x| [I18n.t("activerecord.attributes.pickup_point.providers.#{x}", default: x), x] }
      text_field :name
      text_field :city
      text_field :address
      text_field :phone, label: "Телефон"
      text_field :working_hours, label: "Режим работы"
    end

    tab :location, label: "Координаты" do
      row do
        col(sm: 6) { text_field :lat, label: "Широта (Lat)" }
        col(sm: 6) { text_field :lon, label: "Долгота (Lon)" }
      end
    end

    tab :limits, label: "Ограничения" do
      row do
        col(sm: 6) { number_field :max_weight_kg, step: 0.001, label: "Макс. вес (кг)" }
        col(sm: 6) { number_field :max_volume_m3, step: 0.000001, label: "Макс. объем (м³)" }
      end
    end

    sidebar do
      form_group :status, label: "Статус" do
        check_box :priority, label: "Приоритетный"
        check_box :active, label: "Активен"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
