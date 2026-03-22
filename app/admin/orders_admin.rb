Trestle.resource(:orders) do
  menu do
    item :orders, icon: "fa fa-shopping-cart", group: :sales, priority: 1, label: "Заказы"
  end

  table do
    column :id, label: "ID"
    column :customer_name, label: "Покупатель"
    column :status, label: "Статус" do |order|
      if order.status
        status_text = I18n.t("activerecord.attributes.order.statuses.#{order.status}")
        case order.status.to_sym
        when :completed
          status_tag(status_text, :success)
        when :cancelled
          status_tag(status_text, :danger)
        when :created, :confirmed, :paid
          status_tag(status_text, :info)
        else
          status_tag(status_text, :primary)
        end
      else
        status_tag("Неизвестно (#{order.attributes['status']})", :secondary)
      end
    end
    column :total_amount, label: "Сумма"
    column :created_at, label: "Дата", align: :center
    actions
  end

  form do |order|
    tab :basic, label: "Основное" do
      row do
        col(sm: 6) { static_field :id, label: "ID заказа" }
        col(sm: 6) { static_field :created_at, label: "Дата создания" }
      end
      
      divider
      row do
        col(sm: 6) { text_field :full_name, label: "ФИО получателя" }
        col(sm: 6) { text_field :phone, label: "Телефон" }
      end
      
      static_field :customer_name, label: "Покупатель"
    end

    tab :payment_delivery, label: "Оплата и доставка" do
      row do
        col(sm: 4) { static_field :total_amount, label: "Общая сумма" }
        col(sm: 4) { static_field :delivery_price, label: "Стоимость доставки" }
        col(sm: 4) { static_field :discount_amount, label: "Скидка" }
      end

      static_field :delivery_type, label: "Тип доставки"
      static_field :payment_method, label: "Способ оплаты"
      
      if order.address_json.present?
        static_field :address, label: "Адрес" do
          addr = order.address_json
          "#{addr['city']}, #{addr['street']}, д. #{addr['house']}#{addr['apartment'] ? ', кв. ' + addr['apartment'] : ''}"
        end
      end
    end

    tab :items, label: "Товары" do
      table order.order_items, label: "Товары в заказе" do
        column :product_sku, label: "SKU"
        column :quantity, label: "Кол-во"
        column :price, label: "Цена" do |oi|
          sprintf('%.2f', oi.price.to_f)
        end
      end
    end

    sidebar do
      form_group :order_status, label: "Статус заказа" do
        select :status, Order.statuses.keys.map { |s| [I18n.t("activerecord.attributes.order.statuses.#{s}"), s] }, label: "Статус"
        text_field :track_number, label: "Трек-номер"
      end

      form_group :meta, label: "Метаданные" do
        static_field :id, label: "ID заказа"
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
