Trestle.resource(:search_query_logs, model: SearchQueryLog, readonly: true) do
  menu do
    item :search_query_logs, icon: "fa fa-history", priority: 5, label: "Логи поиска", group: "Аналитика",
                             if: -> { current_user&.allowed_for_admin_resource?(:search_query_logs, :index) }
  end

  table do
    column :created_at, label: "Дата", align: :center
    column :customer, label: "Пользователь" do |record|
      if current_user&.can_view_personal_data?
        record.customer&.username || "Гость"
      elsif record.customer
        "Скрыто"
      else
        "Гость"
      end
    end
    column :query, label: "Запрос"
    column :results_count, label: "Результатов"
    column :clicked_product_sku, label: "Клик по SKU"
    actions
  end

  controller do
    def collection
      super.reorder(created_at: :desc)
    end
  end
end
