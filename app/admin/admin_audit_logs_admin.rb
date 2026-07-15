# frozen_string_literal: true

Trestle.resource(:admin_audit_logs, model: AdminAuditLog) do
  menu do
    item :admin_audit_logs, icon: "fa fa-clipboard-list", group: :system,
                            label: "Журнал действий",
                            if: -> { current_user&.allowed_for_admin_resource?(:admin_audit_logs, :index) }
  end

  collection do
    AdminAuditLog.includes(:actor).recent
  end

  table do
    column :created_at, label: "Дата"
    column :actor, label: "Администратор" do |log|
      log.actor&.full_name || "Системный/удалённый пользователь"
    end
    column :resource, label: "Ресурс"
    column :auditable_id, label: "ID записи"
    column :action, label: "Действие"
    column :request_id, label: "Request ID"
    actions do |toolbar|
      toolbar.show
    end
  end

  form do |log|
    static_field :created_at, label: "Дата"
    static_field :actor, label: "Администратор"
    static_field :resource, label: "Ресурс"
    static_field :auditable_type, label: "Тип записи"
    static_field :auditable_id, label: "ID записи"
    static_field :action, label: "Действие"
    static_field :request_id, label: "Request ID"
    static_field :ip_address, label: "IP"
    static_field :changeset, label: "Изменения" do
      content_tag(:pre, JSON.pretty_generate(log.changeset))
    end
    static_field :metadata, label: "Метаданные" do
      content_tag(:pre, JSON.pretty_generate(log.metadata))
    end
  end
end
