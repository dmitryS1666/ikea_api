Trestle.resource(:cooperation_requests, model: CooperationRequest) do
  menu do
    item :cooperation_requests, icon: "fa fa-handshake", group: :sales, label: "Сотрудничество",
                                if: -> { current_user&.allowed_for_admin_resource?(:cooperation_requests, :index) }
  end

  routes do
    post :add_manager_comment, on: :member
  end

  controller do
    def add_manager_comment
      request_record = admin.find_instance(params)
      Admin::RequestWorkflowService.add_comment!(
        record: request_record,
        actor: current_user,
        body: params[:manager_comment]
      )
      redirect_to admin.instance_path(request_record, action: :edit), notice: "Комментарий добавлен"
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to admin.instance_path(request_record, action: :edit), alert: e.message
    end
  end

  table do
    column :id, link: true
    column :first_name do |request|
      current_user&.can_view_personal_data? ? request.first_name : "Скрыто"
    end
    column :last_name do |request|
      current_user&.can_view_personal_data? ? request.last_name : "Скрыто"
    end
    column :cooperation_type
    column :city do |request|
      current_user&.can_view_personal_data? ? request.city : "Скрыто"
    end
    column :phone do |request|
      current_user&.can_view_personal_data? ? request.phone : "Скрыто"
    end
    column :email do |request|
      current_user&.can_view_personal_data? ? request.email : "Скрыто"
    end
    column :status do |r|
      status_tag(r.status, :info)
    end
    column :created_at, align: :center
    actions
  end

  form do |r|
    if current_user&.can_view_personal_data?
      text_field :first_name, label: "Имя"
      text_field :last_name, label: "Фамилия"
      text_field :company, label: "Компания"
      text_field :city, label: "Город"
      text_field :phone, label: "Телефон"
      text_field :email, label: "Email"
      text_area :comment, label: "Комментарий"
    else
      static_field :personal_data_hidden, label: "Контактные данные" do
        "Скрыто: нет права на просмотр персональных данных"
      end
    end

    text_field :cooperation_type, label: "Тип сотрудничества"
    check_box :personal_data_consent, label: "Согласие с политикой ПД"
    check_box :marketing_email_consent, label: "Согласие на email-уведомления"
    if current_user&.has_admin_permission?(:requests_manage)
      select :status, CooperationRequest::STATUSES.map { |s| [s, s] }, label: "Статус"
      select :assigned_to_id,
        User.active.where(role: %w[admin site_admin manager_requests]).order(:first_name, :username).map { |user| [user.full_name, user.id] },
        label: "Ответственный", include_blank: "Не назначен"
    else
      static_field :status, label: "Статус"
      static_field :assigned_to, label: "Ответственный"
    end

    divider
    render partial: "admin/shared/request_workflow",
           locals: { record: r, admin: admin, can_manage: current_user&.has_admin_permission?(:requests_manage) }
  end
end
