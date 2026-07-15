Trestle.resource(:popular_search_queries, model: PopularSearchQuery) do
  menu do
    item :popular_search_queries, icon: "fa fa-search", group: :catalog, label: "Популярные запросы",
                                  if: -> { current_user&.allowed_for_admin_resource?(:popular_search_queries, :index) }
  end

  table do
    column :query
    column :weight do |record|
      number_with_precision(record.weight || 0, precision: 0)
    end
    column :active do |record|
      status_tag(record.active ? 'Да' : 'Нет', record.active ? :success : :secondary)
    end
    column :created_at, align: :center
    column :updated_at, align: :center
    actions
  end

  form do |record|
    tab :basic, label: "Основное" do
      text_field :query, label: "Запрос"
      number_field :weight, label: "Вес (приоритет)"
    end

    sidebar do
      form_group :status, label: "Статус" do
        check_box :active, label: "Активен"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
