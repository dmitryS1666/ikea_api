Trestle.resource(:content_articles, model: ContentArticle) do
  menu do
    item :content_articles, icon: "fa fa-newspaper", group: :content, label: "Статьи и Контент"
  end

  scopes do
    scope :all, default: true
    scope :tips_ideas, -> { ContentArticle.tips_ideas }
    scope :news, -> { ContentArticle.news }
    scope :published, -> { ContentArticle.visible }
  end

  routes do
    post :remove_product, on: :member
    get :remove_product, on: :member
  end

  controller do
    def remove_product
      article = admin.find_instance(params)
      sku = params[:sku]
      article.content_article_products.where(product_sku: sku).delete_all
      
      flash[:message] = "Товар #{sku} удален из статьи."
      redirect_to admin.path(:show, id: article.id)
    end
  end

  table do
    column :content_type, label: "Тип" do |article|
      ContentArticle.human_attribute_name("content_types.#{article.content_type}")
    end
    
    column :status, label: "Статус" do |article|
      ContentArticle.human_attribute_name("statuses.#{article.status}")
    end
    column :rubric, label: "Рубрика"
    column :title, label: "Заголовок", link: true
    column :slug, label: "Slug (ЧПУ)"
    column :pinned, label: "Закреплен" do |article|
      article.pinned? ? "Да" : "Нет"
    end
    column :published_at, label: "Дата публикации"
    actions
  end

  form do |article|
    tab :general, label: "Основное" do
      row do
        col(sm: 6) do
          select :content_type,
                 ContentArticle.content_types.keys.map { |key| [ContentArticle.human_attribute_name("content_types.#{key}"), key] },
                 label: "Тип контента"
        end
        
        col(sm: 6) do
          select :status,
                 ContentArticle.statuses.keys.map { |key| [ContentArticle.human_attribute_name("statuses.#{key}"), key] },
                 label: "Статус"
        end
      end
      row do
        col(sm: 12) { text_field :title, required: true, label: "Заголовок" }
      end
      row do
        col(sm: 12) { text_field :slug, label: "Slug", hint: "Если не заполнено — будет сгенерировано автоматически" }
      end
      row do
        col(sm: 12) { text_area :excerpt, rows: 3, label: "Короткое описание" }
      end
      row do
        col(sm: 12) do
          render "trestle/content_articles/body_block_builder", article: article
        end
      end
    end

    tab :filters, label: "Фильтры и рубрики" do
      row do
        col(sm: 12) do
          select :rubric,
                 ContentArticle.where.not(rubric: [nil, ""]).pluck(:rubric).uniq.sort,
                 { label: "Рубрика", include_blank: true },
                 { data: { ui: "select2", tags: "true" } }
        end
      end
      row do
        col(sm: 6) do
          text_area :components_input, rows: 3, label: "Компоненты", help: "Одна строка = один компонент"
        end
        col(sm: 6) do
          text_area :projects_input, rows: 3, label: "Проекты", help: "Одна строка = один проект"
        end
      end
    end

    tab :links, label: "Связи с товарами" do
      row do
        col(sm: 6) do
          text_area :product_skus_input, rows: 4, label: "SKU товаров", help: "Артикул каждого товара с новой строки"
          file_field :product_csv, label: "Или загрузить из CSV", accept: ".csv", help: "Файл CSV, где первая колонка — SKU"
        end
        col(sm: 6) do
          select :category_ids_input, 
                 Category.all.order(:name).map { |c| [c.translated_name, c.ikea_id] }, 
                 { label: "Связанные категории", help: "Статья будет отображаться в товарах этих категорий" }, 
                 { multiple: true, data: { ui: "select2" } }
        end
      end

      if article.content_article_products.any?
        row do
          col(sm: 12) do
            accordion_id = "linked-products-accordion-#{article.id}"
            collapse_id = "linked-products-collapse-#{article.id}"
            
            static_field :linked_products_list, label: "Привязанные товары (#{article.content_article_products.count})" do
              content_tag(:div, class: "accordion", id: accordion_id) do
                content_tag(:div, class: "accordion-item") do
                  header = content_tag(:h2, class: "accordion-header", id: "#{collapse_id}-header") do
                    content_tag(:button, "Показать список привязанных товаров", 
                                class: "accordion-button collapsed", 
                                type: "button", 
                                data: { "bs-toggle": "collapse", "bs-target": "##{collapse_id}" }, 
                                aria: { expanded: "false", controls: collapse_id })
                  end
                  
                  body = content_tag(:div, id: collapse_id, 
                                     class: "accordion-collapse collapse", 
                                     aria: { labelledby: "#{collapse_id}-header" }, 
                                     data: { "bs-parent": "##{accordion_id}" }) do
                    content_tag(:div, class: "accordion-body") do
                      table article.content_article_products.includes(:product), class: "table table-condensed" do
                        column :product_sku, label: "SKU" do |cap|
                          if cap.product
                            link_to cap.product_sku, Trestle.lookup(:products).path(:show, id: cap.product.id)
                          else
                            cap.product_sku
                          end
                        end
                        column :name, label: "Название" do |cap|
                          cap.product&.name_ru || "—"
                        end
                        column :actions, label: "" do |cap|
                          link_to admin.path(:remove_product, id: article.id, sku: cap.product_sku), 
                                  method: :post, 
                                  class: "btn btn-xs btn-outline-danger", 
                                  data: { confirm: "Удалить связь с этим товаром?" } do
                            tag.i(class: "fa fa-trash")
                          end
                        end
                      end
                    end
                  end
                  
                  header + body
                end
              end
            end
          end
        end
      end
    end

    tab :seo, label: "SEO-метки" do
      fields_for :seo_meta, article.seo_meta || article.build_seo_meta do |seo|
        seo.text_field :title, label: "SEO Title"
        seo.text_area :description, label: "SEO Description"
        seo.text_field :keywords, label: "SEO Keywords"
        seo.text_field :robots, label: "SEO Robots"
        seo.tinymce :seo_text, label: "SEO Текст"
      end
    end

    sidebar do
      row do
        col(sm: 12) do
          datetime_field :published_at, label: "Дата публикации"
          check_box :active, label: "Активно"
        end
        row do
          col(sm: 12) do
            check_box :pinned, label: "Закрепить сверху"
            number_field :pinned_position, label: "Порядок закрепления"
          end
        end
      end
    end
  end

  params do |params|
    params.require(:content_article).permit(
      :content_type,
      :status,
      :title,
      :slug,
      :excerpt,
      :body_blocks_json,
      :tile_blocks_json,
      :rubric,
      :components_input,
      :projects_input,
      :product_skus_input,
      :category_ids_input,
      :product_csv,
      :pinned,
      :pinned_position,
      :published_at,
      :active,
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end
