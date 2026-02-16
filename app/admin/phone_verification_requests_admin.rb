Trestle.resource(:phone_verification_requests) do
  menu do
    item :phone_verification_requests, icon: "fa fa-phone", label: "Запросы СМС", group: "Settings", priority: 6
  end

  # Scope to show latest first
  scopes do
    scope :all, default: true
  end

  table do
    column :id
    column :phone
    column :code
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
    column :ip_address
    column :created_at, align: :center
    actions
  end

  form do |request|
    static_field :phone
    static_field :code
    static_field :status
    static_field :error_message
    static_field :ip_address
    static_field :user_agent
    static_field :metadata
    static_field :created_at
  end
end
