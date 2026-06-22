Trestle.resource(:users, model: User) do
  routes do
    post :request_call, on: :member
    post :verify_call, on: :member
  end

  menu do
    item :users, icon: "fa fa-users", group: :sales, priority: 2, label: "Пользователи"
  end

  table do
    column :id
    column :username, link: true
    column :phone
    column :email, label: "Электронная почта"
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
    column :passport_verified?, label: "Паспорт" do |user|
      status_tag(user.passport_verified? ? 'Верифицирован' : 'Не верифицирован', 
                 user.passport_verified? ? :success : :warning)
    end
    column :personal_data_consent, label: "ПД" do |user|
      status_tag(user.personal_data_consent? ? 'Да' : 'Нет', user.personal_data_consent? ? :success : :danger)
    end
    column :email_marketing, label: "Email" do |user|
      status_tag(user.email_marketing? ? 'Да' : 'Нет', user.email_marketing? ? :success : :secondary)
    end
    column :newsletter_consent, label: "Рассылка" do |user|
      status_tag(user.newsletter_consent? ? 'Да' : 'Нет', user.newsletter_consent? ? :success : :secondary)
    end
    column :is_active do |user|
      status_tag(user.is_active? ? 'Да' : 'Нет', 
                 user.is_active? ? :success : :danger)
    end
    column :created_at, align: :center
    actions do |toolbar, user|
      toolbar.link "Запрос звонка", admin.instance_path(user, action: :request_call), method: :post, icon: "fa fa-phone", class: "btn btn-info"
    end
  end

  controller do
    def request_call
      user = admin.find_instance(params)
      if user.phone.blank?
        flash[:error] = "У пользователя не указан номер телефона"
      else
        PhoneAuthService.send_code(
          phone: user.phone, 
          metadata: { 
            user_id: user.id, 
            context: 'passport_update',
            admin_id: current_user.id
          }
        )
        flash[:message] = "Запрос на звонок отправлен на #{user.phone}"
      end
      redirect_to admin.path(:show, id: user.id)
    end

    def verify_call
      user = admin.find_instance(params)
      last4 = params[:last4]
      if last4.blank?
        flash[:error] = "Введите 4 цифры"
        redirect_to admin.path(:show, id: user.id) and return
      end

      # Проверка через VerificationCode (то же, что в PhoneAuthService)
      verification = VerificationCode.valid_code(user.phone.gsub(/\D/, ''), last4).first
      
      if verification.nil?
        flash[:error] = "Неверный код (последние 4 цифры) или срок действия истек"
      else
        verification.destroy!
        user.update!(passport_verified_at: Time.current)
        flash[:message] = "Паспорт успешно верифицирован через звонок"
      end
      redirect_to admin.path(:show, id: user.id)
    end
  end

  form do |user|
    tab :basic, label: "Основные данные" do
      row do
        col(sm: 4) { text_field :last_name, label: "Фамилия" }
        col(sm: 4) { text_field :first_name, label: "Имя" }
        col(sm: 4) { text_field :middle_name, label: "Отчество" }
      end
      row do
        col(sm: 6) { text_field :username, label: "Логин (публичный)" }
        col(sm: 6) { text_field :email, label: "Электронная почта" }
      end
      row do
        col(sm: 6) { text_field :phone, label: "Телефон" }
        col(sm: 6) { select :country_code, %w[RB РФ РК], label: "Страна" }
      end
      row do
        col(sm: 6) { date_field :dob, label: "Дата рождения" }
        col(sm: 6) { select :gender, User::GENDER_OPTIONS, label: "Пол" }
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
      check_box :personal_data_consent, label: "Согласие на обработку ПД"
      datetime_field :personal_data_consented_at, label: "Дата согласия на ПД"
    end

    tab :consents, label: "История согласий" do
      table user.consent_records.ordered.limit(50), admin: :consent_records do
        column :created_at, label: "Дата"
        column :consent_type, label: "Тип"
        column :accepted, label: "Принято" do |record|
          status_tag(record.accepted? ? "Да" : "Нет", record.accepted? ? :success : :danger)
        end
        column :legal_page_slug, label: "Документ"
        column :legal_page_version_at, label: "Версия документа"
        column :source, label: "Источник"
      end
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

        divider

        static_field :verification_history, label: "История верификаций через звонок" do
          phone_normalized = user.phone.to_s.gsub(/\D/, '')
          pending_v = VerificationCode.where(phone: phone_normalized).where('expires_at > ?', Time.current).order(created_at: :desc).first
          
          res = if pending_v
            content_tag(:div, class: "well", style: "background-color: #fff9c4; border: 1px solid #ffd600;") do
              content_tag(:p, "Ожидает подтверждения (последние 4 цифры):") +
              form_tag(admin.instance_path(user, action: :verify_call), method: :post, class: "form-inline") do
                text_field_tag(:last4, nil, class: "form-control input-sm", placeholder: "1234", maxlength: 4, style: "width: 100px; display: inline-block;") +
                submit_tag("Подтвердить", class: "btn btn-success btn-sm", style: "margin-left: 10px;")
              end
            end
          else
            link_to("Запросить звонок для верификации", admin.instance_path(user, action: :request_call), method: :post, class: "btn btn-info btn-sm")
          end

          verifications = PhoneVerificationRequest.where(phone: phone_normalized, context: 'passport_update').order(id: :desc).limit(5)
          res += content_tag(:hr)
          res += if verifications.any?
            content_tag(:table, class: "table") do
              content_tag(:thead) do
                content_tag(:tr) do
                  content_tag(:th) { "Дата" }
                  content_tag(:th) { "Статус" }
                  content_tag(:th) { "Код" }
                end
              end +
              content_tag(:tbody) do
                verifications.map do |v|
                  content_tag(:tr) do
                    content_tag(:td) { v.created_at.strftime("%d.%m.%Y %H:%M") } +
                    content_tag(:td) do
                      case v.status
                      when 'success'
                        status_tag("Звонок прошел", :success)
                      when 'error'
                        status_tag("Ошибка", :danger)
                      else
                        status_tag(v.status, :warning)
                      end
                    end +
                    content_tag(:td) { v.code }
                  end
                end.reduce(:+)
              end
            end
          else
            content_tag(:p, "Записей не найдено")
          end
          res
        end
      else
        static_field :no_passport, label: "Статус" do
          "Данные не предоставлены"
        end
      end
    end

    sidebar do
      password_field :password, label: "Пароль"
      password_field :password_confirmation, label: "Подтверждение пароля"
      
      row do
        col(sm: 12) { select :role, { 'Пользователь' => 'user', 'Менеджер' => 'manager', 'Администратор' => 'admin' }, label: "Роль" }
      end
      row do
        col(sm: 12) { check_box :is_active, label: "Активен" }
      end
      row do
        col(sm: 12) { static_field :created_at, label: "Дата регистрации" }
      end
      row do
        col(sm: 12) { static_field :updated_at, label: "Последнее обновление" }
      end
    end
  end

  params do |params|
    params.require(:user).permit(
      :last_name, :first_name, :middle_name, :username, :email, :phone, :country_code,
      :dob, :gender, :region, :city, :postcode, :street, :house, :building, :apartment,
      :address, :email_marketing, :telegram_marketing, :newsletter_consent, :gdpr_consent,
      :personal_data_consent, :personal_data_consented_at,
      :password, :password_confirmation, :role, :is_active
    )
  end
end
