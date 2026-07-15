Trestle.resource(:product_recommendation_settings, model: ProductRecommendationSetting, singleton: true) do
  menu do
    item :product_recommendation_settings, icon: "fa fa-magic", group: :catalog, priority: 10,
                                           label: "Рекомендации в корзине",
                                           if: -> { current_user&.allowed_for_admin_resource?(:product_recommendation_settings, :index) }
  end

  controller do
    def update
      setting = admin.find_instance(params)

      if setting.update(product_recommendation_setting_params)
        flash[:message] = "Настройки рекомендаций в корзине сохранены"
        redirect_to admin.instance_path(setting)
      else
        flash.now[:error] = "Ошибка: #{setting.errors.full_messages.join(', ')}"
        render :edit
      end
    end

    private

    def product_recommendation_setting_params
      params.require(:product_recommendation_setting).permit(
        :source_type,
        :active,
        :category_id,
        :product_skus_input,
        product_skus: []
      )
    end
  end

  form do |setting|
    row do
      col(sm: 12) do
        select :source_type,
               [["Через SKU", :sku_list], ["Через поиск товаров", :product_list], ["Через категорию", :category]],
               { label: "Источник" },
               { class: "js-product-recommendation-source" }
      end
    end

    row do
      col(sm: 12) do
        check_box :active, label: "Активно"
      end
    end

    row do
      col(sm: 12) do
        content_tag(:div, class: "js-recommendation-source-block", data: { source_block: "sku_list" }) do
          text_area :product_skus_input,
                    rows: 6,
                    label: "SKU списком",
                    help: "Один SKU на строку или через запятую"
        end
      end
    end

    row do
      col(sm: 12) do
        content_tag(:div, class: "js-recommendation-source-block", data: { source_block: "product_list" }) do
          selected_products = Product.where(sku: Array(setting.product_skus)).index_by(&:sku)
          options = Array(setting.product_skus).map do |sku|
            product = selected_products[sku]
            label = product.present? ? "#{product.name.presence || product.sku} (#{product.sku})" : sku
            [label, sku]
          end

          label_tag = content_tag(:label, "Товары")
          select_tag_html = select_tag(
            "product_recommendation_setting[product_skus][]",
            options_for_select(options, Array(setting.product_skus)),
            multiple: true,
            class: "form-control",
            data: { ui: "select2-ajax", ajax_url: main_app.admin_products_search_path },
            include_blank: false
          )
          help_tag = content_tag(:div, "Начните вводить имя товара или SKU.", class: "text-muted", style: "margin-top: 6px;")

          label_tag + select_tag_html + help_tag
        end
      end
    end

    row do
      col(sm: 12) do
        content_tag(:div, class: "js-recommendation-source-block", data: { source_block: "category" }) do
          select :category_id,
                 Category.active.order(:translated_name, :name).map { |c| ["#{c.translated_name.presence || c.name} (#{c.ikea_id})", c.ikea_id] },
                 { label: "Категория", include_blank: "Выберите категорию" },
                 { data: { ui: "select2" } }
        end
      end
    end
  end
end
