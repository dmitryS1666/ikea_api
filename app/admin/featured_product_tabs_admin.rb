Trestle.resource(:featured_product_tabs, model: FeaturedProductTab) do
  menu do
    item :featured_product_tabs,
         icon: "fa fa-th-list",
         group: :catalog,
         priority: 11,
         label: "Табы подборок товаров"
  end

  table do
    column :list_key, label: "Тип списка" do |tab|
      tab.list_key_label
    end
    column :position, label: "Порядок"
    column :category_id, label: "Категория"
    column :product_skus, label: "SKU" do |tab|
      Array(tab.product_skus).first(5).join(", ").presence || "—"
    end
    column :active, label: "Активно" do |tab|
      tab.active? ? "Да" : "Нет"
    end
    actions
  end

  form do |tab|
    root_categories =
      Category.active
              .top_level
              .order(:root_position, :translated_name, :name)
              .map { |category| ["#{category.translated_name.presence || category.name} (#{category.ikea_id})", category.ikea_id] }

    row do
      col(sm: 6) do
        select :list_key,
               FeaturedProductTab::LIST_KEY_LABELS.map { |key, label| [label, key] },
               label: "Тип списка"
      end
      col(sm: 3) { number_field :position, label: "Порядок", min: 0 }
      col(sm: 3) { check_box :active, label: "Активно" }
    end

    row do
      col(sm: 12) do
        select :category_id,
               root_categories,
               { label: "Категория таба", include_blank: "Выберите категорию" },
               { data: { ui: "select2" } }
      end
    end

    row do
      col(sm: 12) do
        text_area :product_skus_input,
                  rows: 8,
                  label: "SKU товаров таба",
                  value: tab.product_skus_input,
                  help: "Один SKU на строку (или через запятую/точку с запятой). Порядок SKU будет сохранен в API."
      end
    end
  end

  params do |params|
    params.require(:featured_product_tab).permit(
      :list_key,
      :position,
      :active,
      :category_id,
      :product_skus_input,
      product_skus: []
    )
  end
end
