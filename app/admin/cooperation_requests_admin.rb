Trestle.resource(:cooperation_requests, model: CooperationRequest) do
  menu do
    item :cooperation_requests, icon: "fa fa-handshake", group: :sales, label: "Сотрудничество"
  end

  table do
    column :id, link: true
    column :first_name
    column :last_name
    column :cooperation_type
    column :city
    column :phone
    column :email
    column :status do |r|
      status_tag(r.status, :info)
    end
    column :created_at, align: :center
    actions
  end

  form do |r|
    text_field :first_name, label: "Имя"
    text_field :last_name, label: "Фамилия"
    text_field :cooperation_type, label: "Тип сотрудничества"
    text_field :company, label: "Компания"
    text_field :city, label: "Город"
    text_field :phone, label: "Телефон"
    text_field :email, label: "Email"
    text_area :comment, label: "Комментарий"
    check_box :personal_data_consent, label: "Согласие с политикой ПД"
    check_box :marketing_email_consent, label: "Согласие на email-уведомления"
    select :status, CooperationRequest::STATUSES.map { |s| [s, s] }, label: "Статус"
  end
end

