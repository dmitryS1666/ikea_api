Trestle.resource(:user_delivery_addresses, model: UserDeliveryAddress) do
  menu do
    item :user_delivery_addresses, icon: "fa fa-map-marker", group: :sales, priority: 3, label: "Адреса доставки",
                                    if: -> { current_user&.allowed_for_admin_resource?(:user_delivery_addresses, :index) }
  end

  collection do
    UserDeliveryAddress.alive.includes(:user).order(id: :desc)
  end

  table do
    column :id, link: true, sort: true
    column :user, header: "Пользователь" do |address|
      if address.user
        link_to(
          address.user.full_name,
          Trestle.lookup(:users).path(:show, id: address.user.id),
          data: { turbo: false }
        )
      else
        "—"
      end
    end
    column :formatted_address, header: "Адрес"
    column :elevator_type, header: "Лифт" do |address|
      address.elevator_type_label || "—"
    end
    column :intercom, header: "Домофон" do |address|
      address.intercom.presence || "—"
    end
    column :is_private_house, header: "Частный дом", align: :center do |address|
      status_tag(address.is_private_house? ? "Да" : "Нет", address.is_private_house? ? :info : :secondary)
    end
    column :created_at, align: :center, sort: true
    actions
  end

  form do |address|
    tab :basic, label: "Адрес" do
      static_field :user, label: "Пользователь" do
        if address.user
          link_to(
            address.user.full_name,
            Trestle.lookup(:users).path(:show, id: address.user.id),
            data: { turbo: false }
          )
        else
          "—"
        end
      end

      row do
        col(sm: 4) { text_field :city, label: "Город" }
        col(sm: 4) { text_field :street, label: "Улица" }
        col(sm: 4) { text_field :house, label: "Дом" }
      end

      row do
        col(sm: 3) { text_field :building, label: "Корпус" }
        col(sm: 3) { text_field :apartment, label: "Квартира" }
        col(sm: 2) { text_field :entrance, label: "Подъезд" }
        col(sm: 2) { text_field :floor, label: "Этаж" }
        col(sm: 2) { check_box :is_private_house, label: "Частный дом" }
      end

      row do
        col(sm: 4) do
          select :elevator_type, UserDeliveryAddress::ELEVATOR_TYPE_OPTIONS, include_blank: "Не указан", label: "Лифт"
        end
        col(sm: 4) { text_field :intercom, label: "Домофон" }
        col(sm: 2) { text_field :lat, label: "Широта" }
        col(sm: 2) { text_field :lng, label: "Долгота" }
      end

      text_area :comment, label: "Комментарий"
      static_field :formatted_address, label: "Форматированный адрес"
    end

    sidebar do
      static_field :id, label: "ID"
      static_field :created_at, label: "Создан"
      static_field :updated_at, label: "Обновлён"
      static_field :deleted_at, label: "Удалён"
    end
  end

  params do |params|
    params.require(:user_delivery_address).permit(
      :city, :street, :house, :building, :apartment, :entrance, :floor,
      :elevator_type, :intercom, :is_private_house, :lat, :lng, :comment
    )
  end
end
