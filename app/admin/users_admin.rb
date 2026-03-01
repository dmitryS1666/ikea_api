Trestle.resource(:users, model: User) do
  menu do
    item :users, icon: "fa fa-users", priority: 5, label: "Пользователи", group: "Settings"
  end

  table do
    column :id
    column :username, link: true
    column :phone
    column :email
    column :role do |user|
      case user.role
      when 'admin'
        status_tag('Администратор', :success)
      when 'manager'
        status_tag('Менеджер', :info)
      else
        status_tag('Пользователь', :secondary)
      end
    end
    column :passport_verified? do |user|
      status_tag(user.passport_verified? ? 'Верифицирован' : 'Не верифицирован', 
                 user.passport_verified? ? :success : :warning)
    end
    column :is_active do |user|
      status_tag(user.is_active? ? 'Активен' : 'Неактивен', 
                 user.is_active? ? :success : :danger)
    end
    column :created_at, align: :center
    actions
  end

  form do |user|
    tab :basic, label: "Основные данные" do
      row do
        col(sm: 4) { text_field :last_name, label: "Фамилия" }
        col(sm: 4) { text_field :first_name, label: "Имя" }
        col(sm: 4) { text_field :middle_name, label: "Отчество" }
      end
      row do
        col(sm: 6) { text_field :username, label: "Username (публичный)" }
        col(sm: 6) { text_field :email }
      end
      row do
        col(sm: 6) { text_field :phone }
        col(sm: 6) { select :country_code, %w[RB РФ РК] }
      end
      row do
        col(sm: 6) { date_field :dob, label: "Дата рождения" }
        col(sm: 6) { select :gender, %w[Male Female], label: "Пол" }
      end
      
      row do
        col(sm: 4) { text_field :region, label: "Область/Регион" }
        col(sm: 4) { text_field :city, label: "Город" }
        col(sm: 4) { text_field :postcode, label: "Индекс" }
      end
      row do
        col(sm: 6) { text_field :street, label: "Улица" }
        col(sm: 2) { text_field :house, label: "Дом" }
        col(sm: 2) { text_field :building, label: "Корпус" }
        col(sm: 2) { text_field :apartment, label: "Кв." }
      end
      text_area :address, label: "Адрес доставки (полный)"
    end

    tab :marketing, label: "Маркетинг" do
      check_box :email_marketing, label: "Рассылка через Email"
      check_box :telegram_marketing, label: "Рассылка через Telegram"
      check_box :newsletter_consent, label: "Общее согласие на рассылку"
      check_box :gdpr_consent, label: "Согласие GDPR"
    end

    tab :passport, label: "Паспортные данные" do
      if user.encrypted_passport_json.present?
        data = user.passport_data || {}
        static_field :passport_info do
          content_tag(:div, class: "well") do
            content_tag(:p) { "Фамилия: #{data['last_name']}" } +
            content_tag(:p) { "Имя: #{data['first_name']}" } +
            content_tag(:p) { "Отчество: #{data['middle_name']}" } +
            content_tag(:p) { "Серия: #{data['series']}" } +
            content_tag(:p) { "Номер: #{data['number'] || data['passport_number']}" } +
            content_tag(:p) { "Дата выдачи: #{data['issue_date']}" } +
            content_tag(:p) { "Кем выдан: #{data['issued_by']}" } +
            content_tag(:p) { "Идентификационный номер: #{data['identification_number']}" } +
            content_tag(:p) { "Дата рождения: #{data['dob']}" } +
            content_tag(:hr) +
            content_tag(:p) { "Область/Регион: #{data['region']}" } +
            content_tag(:p) { "Город: #{data['city']}" } +
            content_tag(:p) { "Индекс: #{data['postcode']}" } +
            content_tag(:p) { "Улица: #{data['street']}" } +
            content_tag(:p) { "Дом: #{data['house']}" } +
            content_tag(:p) { "Корпус: #{data['building']}" } +
            content_tag(:p) { "Квартира: #{data['apartment']}" }
          end
        end
        
        datetime_field :passport_verified_at, label: "Дата верификации"
      else
        static_field :no_passport, label: "Статус" do
          "Данные не предоставлены"
        end
      end
    end

    sidebar do
      password_field :password
      password_field :password_confirmation
      
      row do
        col(sm: 12) { select :role, { 'Пользователь' => 'user', 'Менеджер' => 'manager', 'Администратор' => 'admin' } }
      end
      row do
        col(sm: 12) { check_box :is_active }
      end
    end
  end
end

