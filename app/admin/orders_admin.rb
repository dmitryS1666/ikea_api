Trestle.resource(:orders) do
  menu do
    item :orders, icon: "fa fa-shopping-cart", priority: 1, label: "Заказы", group: "Sales"
  end

  table do
    column :id
    column :user
    column :status do |order|
      status_text = I18n.t("activerecord.attributes.order.status.#{order.status}")
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
    end
    column :total_amount
    column :created_at, align: :center
    actions
  end

  form do |order|
    row do
      col(sm: 6) { static_field :id }
      col(sm: 6) { select :status, Order.statuses.keys.map { |s| [I18n.t("activerecord.attributes.order.status.#{s}"), s] } }
    end

    row do
      col(sm: 6) { static_field :user }
      col(sm: 6) { text_field :track_number }
    end

    row do
      col(sm: 4) { static_field :total_amount }
      col(sm: 4) { static_field :delivery_price }
      col(sm: 4) { static_field :discount_amount }
    end

    row do
      col(sm: 6) { text_field :full_name }
      col(sm: 6) { text_field :phone }
    end

    static_field :delivery_type
    static_field :payment_method
    
    # ... другие поля по необходимости
  end
end
