# frozen_string_literal: true

Trestle.resource(:admin_role_permissions, model: AdminRolePermission) do
  menu do
    item :admin_role_permissions, icon: "fa fa-key", group: :system, label: "Права ролей",
                                  if: -> { current_user&.allowed_for_admin_resource?(:admin_role_permissions, :index) }
  end

  remove_action :new, :create, :destroy

  collection do
    AdminRolePermission.ensure_defaults!
    AdminRolePermission.ordered
  end

  table do
    column :role, label: "Роль" do |record|
      link_to record.role_label, admin.instance_path(record, action: :edit)
    end
    column :enabled_count, label: "Включено прав" do |record|
      enabled = record.permissions_hash.count { |_, value| value }
      "#{enabled} / #{User::ADMIN_PERMISSION_KEYS.size}"
    end
    column :updated_at, label: "Обновлено", align: :center
    actions do |toolbar|
      toolbar.edit
    end
  end

  form do |record|
    static_field :role, label: "Роль" do
      content_tag(:div) do
        content_tag(:h3, record.role_label, class: "mt-0") +
          content_tag(:p, class: "text-muted mb-0") do
            "Включите или выключите права роли. Сохранение сразу меняет доступ всех сотрудников с этой ролью (кроме индивидуальных сужений в карточке пользователя)."
          end
      end
    end

    User::ADMIN_PERMISSION_KEYS.each do |permission_key|
      check_box :"permission_#{permission_key}", label: User.permission_label(permission_key)
    end

    sidebar do
      form_group :actions, label: "Действия" do
        button_to "Сбросить к умолчанию",
                  admin.instance_path(record, action: :reset_defaults),
                  method: :post,
                  class: "btn btn-warning btn-block",
                  data: { confirm: "Вернуть права роли «#{record.role_label}» к значениям из кода?" }
      end

      form_group :hint, label: "Подсказка" do
        content_tag(:p, class: "text-muted small mb-0") do
          "Список ролей фиксированный. Здесь меняются только их права."
        end
      end
    end
  end

  controller do
    def index
      AdminRolePermission.ensure_defaults!
      super
    end

    def update
      record = admin.find_instance(params)
      attrs = role_permission_params

      if record.update(attrs)
        flash[:message] = "Права роли «#{record.role_label}» сохранены"
        redirect_to admin.instance_path(record, action: :edit)
      else
        flash.now[:error] = record.errors.full_messages.join(", ")
        render :edit, status: :unprocessable_entity
      end
    end

    def reset_defaults
      record = admin.find_instance(params)
      record.reset_to_defaults!
      flash[:message] = "Права роли «#{record.role_label}» сброшены к значениям по умолчанию"
      redirect_to admin.instance_path(record, action: :edit)
    end

    private

    def role_permission_params
      permitted = User::ADMIN_PERMISSION_KEYS.map { |key| :"permission_#{key}" }
      raw = params.fetch(:admin_role_permission, {}).permit(*permitted)

      # unchecked boxes are absent from POST — treat missing as false
      User::ADMIN_PERMISSION_KEYS.each_with_object({}) do |key, memo|
        memo[:"permission_#{key}"] = ActiveModel::Type::Boolean.new.cast(raw[:"permission_#{key}"])
      end
    end
  end

  routes do
    post :reset_defaults, on: :member
  end
end
