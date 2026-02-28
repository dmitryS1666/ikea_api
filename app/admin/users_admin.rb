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
    tab "Основные данные" do
      row do
        col(sm: 6) { text_field :username }
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
      text_area :address, label: "Адрес доставки"
      
      password_field :password
      password_field :password_confirmation
      
      row do
        col(sm: 6) { select :role, { 'Пользователь' => 'user', 'Менеджер' => 'manager', 'Администратор' => 'admin' } }
        col(sm: 6) { check_box :is_active }
      end
    end

    tab "Маркетинг" do
      check_box :email_marketing, label: "Рассылка через Email"
      check_box :telegram_marketing, label: "Рассылка через Telegram"
      check_box :newsletter_consent, label: "Общее согласие на рассылку"
      check_box :gdpr_consent, label: "Согласие GDPR"
    end

    tab "Паспортные данные" do
      if user.encrypted_passport_json.present?
        data = user.passport_data || {}
        static_field :passport_info do
          content_tag(:div, class: "well") do
            content_tag(:p) { "Номер: #{data['passport_number'] || data[:passport_number]}" } +
            content_tag(:p) { "ФИО: #{data['full_name'] || data[:full_name]}" } +
            content_tag(:p) { "Дата выдачи: #{data['issue_date'] || data[:issue_date]}" }
          end
        end
        
        datetime_field :passport_verified_at, label: "Дата верификации"
      else
        static_field :no_passport, label: "Статус" do
          "Данные не предоставлены"
        end
      end
    end
  end
end

