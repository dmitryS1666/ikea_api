Trestle.resource(:phone_verification_requests) do
  menu do
    item :phone_verification_requests, icon: "fa fa-phone", label: "Запросы звонков", group: "Клиенты", priority: 6
  end

  # Scope to show latest first
  collection do
    PhoneVerificationRequest.order(id: :desc)
  end

  table do
    column :id
    column :phone
    column :code
    column :context do |request|
      case request.context
      when 'auth'
        status_tag('Вход/Рег', :primary)
      when 'change_phone'
        status_tag('Смена телефона', :info)
      when 'passport_update'
        status_tag('Паспорт', :warning)
      else
        request.context
      end
    end
    column :user_id do |request|
      if request.user_id
        link_to(request.user_id, admin.path(:users, action: :show, id: request.user_id))
      else
        "-"
      end
    end
    column :status do |request|
      case request.status
      when 'success'
        status_tag(request.status, :success)
      when 'error'
        status_tag(request.status, :danger)
      else
        status_tag(request.status, :info)
      end
    end
    column :error_message
    column :created_at, align: :center
    actions
  end

  form do |request|
    row do
      col(sm: 3) { static_field :phone, label: "Телефон" }
      col(sm: 3) { static_field :code, label: "Код" }
      col(sm: 3) do
        static_field :status, label: "Статус" do
          tag = case request.status
          when 'success'
            status_tag(request.status, :success)
          when 'error'
            status_tag(request.status, :danger)
          else
            status_tag(request.status, :info)
          end
          content_tag(:div, tag, style: "font-size: 1.5rem; margin-top: 5px;")
        end
      end
    end
    divider
    row do
      col(sm: 3) do
        static_field :context, label: "Контекст" do
          tag = case request.context
          when 'auth'
            status_tag('Вход/Рег', :primary)
          when 'change_phone'
            status_tag('Смена телефона', :info)
          when 'passport_update'
            status_tag('Паспорт', :warning)
          else
            status_tag(request.context, :info)
          end
          content_tag(:div, tag, style: "font-size: 1.5rem; margin-top: 5px;")
        end
      end
      col(sm: 3) do
        static_field :user_id, label: "Пользователь" do
          if request.user_id
            link_to("Пользователь ##{request.user_id}", admin.path(:users, action: :show, id: request.user_id), class: "btn btn-default btn-sm")
          else
            "-"
          end
        end
      end
    end
    divider
    row do
      col(sm: 6) { text_area :error_message, label: "Сообщение об ошибке" }
    end
    sidebar do
      row do
        col(sm: 12) { static_field :user_agent, label: "User Agent (браузер)" }
        col(sm: 12) { static_field :created_at, label: "Дата создания" }
      end
    end
  end
end
