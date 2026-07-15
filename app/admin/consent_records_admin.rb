Trestle.resource(:consent_records, model: ConsentRecord) do
  menu do
    item :consent_records, icon: "fa fa-file-signature", group: :sales, priority: 3, label: "История согласий",
                           if: -> { current_user&.allowed_for_admin_resource?(:consent_records, :index) }
  end

  remove_action :new, :create, :edit, :update, :destroy

  collection do
    ConsentRecord.includes(:user, :order).ordered
  end

  table do
    column :created_at, align: :center
    column :user do |record|
      if record.user
        link_to(record.user.full_name, Trestle.lookup(:users).path(:show, id: record.user_id), data: { turbo: false })
      else
        "—"
      end
    end
    column :order_id, label: "Заказ"
    column :consent_type, label: "Тип"
    column :accepted, label: "Принято" do |record|
      status_tag(record.accepted? ? "Да" : "Нет", record.accepted? ? :success : :danger)
    end
    column :legal_page_slug, label: "Документ"
    column :legal_page_version_at, label: "Версия документа", align: :center
    column :source, label: "Источник"
    actions
  end

  form do |record|
    static_field :created_at, label: "Дата"
    static_field :consent_type, label: "Тип"
    static_field :accepted, label: "Принято" do
      status_tag(record.accepted? ? "Да" : "Нет", record.accepted? ? :success : :danger)
    end
    static_field :legal_page_slug, label: "Документ"
    static_field :legal_page_version_at, label: "Версия документа"
    static_field :source, label: "Источник"
    static_field :metadata, label: "Метаданные" do
      content_tag(:pre, JSON.pretty_generate(record.metadata))
    end
  end
end
