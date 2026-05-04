Trestle.resource(:orders) do
  menu do
    item :orders, icon: "fa fa-shopping-cart", group: :sales, priority: 1, label: "Заказы"
  end

  table do
    column :id
    column :customer_name
    column :status, align: :center do |order|
      if order.status
        status_text = I18n.t("activerecord.attributes.order.statuses.#{order.status}")
        main_tag =
          case order.status.to_sym
          when :completed
            status_tag(status_text, :success)
          when :cancelled
            status_tag(status_text, :danger)
          when :created
            status_tag(status_text, :info)
          when :processing, :confirmed, :paid, :purchased
            status_tag(status_text, :primary)
          when :shipped, :arrived_pvz, :handed_to_courier, :handed_to_courier_ikeya
            status_tag(status_text, :info)
          else
            status_tag(status_text, :warning)
          end

        if order.checkout_draft
          safe_join([main_tag, tag.br, status_tag("Черновик", :warning)])
        else
          main_tag
        end
      else
        status_tag("Неизвестно", :secondary)
      end
    end
    column :total_amount
    column :created_at, align: :center
    actions
  end

  form do |order|
    tab :basic, label: "Основное" do
      row do
        col(sm: 4) { static_field :id, label: "ID заказа" }
        col(sm: 4) do
          static_field :status, label: "Текущий статус" do
            if order.status
              status_text = I18n.t("activerecord.attributes.order.statuses.#{order.status}")
              main_tag =
                case order.status.to_sym
                when :completed then status_tag(status_text, :success)
                when :cancelled then status_tag(status_text, :danger)
                when :created then status_tag(status_text, :info)
                when :processing, :confirmed, :paid, :purchased then status_tag(status_text, :primary)
                when :shipped, :arrived_pvz, :handed_to_courier, :handed_to_courier_ikeya then status_tag(status_text, :info)
                else status_tag(status_text, :warning)
                end

              if order.checkout_draft
                safe_join([main_tag, tag.br, status_tag("Черновик", :warning)])
              else
                main_tag
              end
            else
              status_tag("Неизвестно", :secondary)
            end
          end
        end
        col(sm: 4) { static_field :created_at, label: "Дата создания" }
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

      if order.payment_url.present?
        static_field :payment_url, label: "Ссылка на оплату (WebPay)" do
          admin_link_to(order.payment_url, order.payment_url, target: "_blank", rel: "noopener")
        end
      end

      if order.payment_link_token.present?
        static_field :payment_link_token, label: "Токен ссылки оплаты"
      end

      if order.payment_expires_at.present?
        static_field :payment_expires_at, label: "Ссылка действует до"
      end
      
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
