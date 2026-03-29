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
    post :add_product, on: :member
    get :remove_product, on: :member
    post :duplicate, on: :member
    get :duplicate, on: :member
  end

  controller do
    def remove_product
      article = admin.find_instance(params)
      sku = params[:sku].to_s.strip

      if article.news?
        article.remove_product_from_body_blocks!(sku)
      else
        article.content_article_products.where(product_sku: sku).delete_all
      end

      flash[:message] = "Товар #{sku} удален из статьи."
      redirect_to admin.path(:edit, id: article.id)
    end

    def add_product
      article = admin.find_instance(params)
      sku = params[:sku].to_s.strip
      product = Product.find_by(sku: sku)

      if article.news?
        flash[:error] = "Для новости связи с товарами формируются из блока 'Сетка товаров'."
      elsif product
        if article.content_article_products.exists?(product_sku: sku)
          flash[:message] = "Товар #{sku} уже привязан."
        else
          position = article.content_article_products.maximum(:position).to_i + 1
          article.content_article_products.create!(product_sku: sku, position: position, source: :manual)
          flash[:message] = "Товар #{sku} добавлен."
        end
      else
        flash[:error] = "Товар #{sku} не найден."
      end

      redirect_to admin.path(:edit, id: article.id)
    end

    def duplicate
      original = admin.find_instance(params)
      copy = original.dup
      copy.title = "#{original.title} (Копия)"
      copy.slug = nil # Будет сгенерирован автоматически из заголовка
      copy.status = :draft
      copy.published_at = nil
      copy.active = false
      
      if copy.save
        # Копируем SEO-мета
        if original.seo_meta
          copy_seo = original.seo_meta.dup
          copy_seo.seoable = copy
          copy_seo.save
        end
        
        # Копируем привязанные товары
        original.content_article_products.each do |cap|
          copy.content_article_products.create(cap.attributes.except("id", "content_article_id", "created_at", "updated_at"))
        end
        
        # Копируем привязанные категории
        original.content_article_categories.each do |cac|
          copy.content_article_categories.create(cac.attributes.except("id", "content_article_id", "created_at", "updated_at"))
        end

        # Изображения в блоках подцепятся автоматически через after_save :sync_body_block_images
        # так как signed_id остались в body_blocks (JSON).

        flash[:message] = "Статья успешно скопирована. Вы находитесь в режиме редактирования копии."
        redirect_to admin.path(:edit, id: copy.id)
      else
        flash[:error] = "Ошибка при копировании статьи: #{copy.errors.full_messages.join(", ")}"
        redirect_to admin.path(:show, id: original.id)
      end
    end
  end

  table do
    column :content_type do |article|
      ContentArticle.human_attribute_name("content_types.#{article.content_type}")
    end
    
    column :status do |article|
      ContentArticle.human_attribute_name("statuses.#{article.status}")
    end
    column :rubric
    column :title, link: true
    column :slug
    column :pinned do |article|
      article.pinned? ? "Да" : "Нет"
    end
    column :published_at
    
    column :actions, label: "Действия" do |article|
      link_to admin.path(:duplicate, id: article.id),
              class: "btn btn-xs btn-outline-info",
              title: "Копировать",
              data: { confirm: "Создать копию этой статьи?", turbo: false } do
        tag.i(class: "fa fa-copy")
      end
    end
    
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
      if article.news?
        row do
          col(sm: 12) do
            content_tag(:div, "Для новости связи с товарами используются данные из блока 'Сетка товаров'. Здесь доступен только просмотр и удаление.", class: "alert alert-info")
          end
        end
      else
        row do
          col(sm: 12) do
            content_tag(:div, class: "article-links-box") do
              concat(select_tag :product_sku_search,
                     "",
                     class: "form-control article-links-search",
                     placeholder: "Начните ввод названия или SKU...",
                     data: { ui: "select2-ajax", ajax_url: main_app.admin_products_search_path })
              concat(content_tag(:button, "Добавить товар",
                                 type: "button",
                                 class: "btn btn-primary article-links-add-btn",
                                 data: { add_url: admin.path(:add_product, id: article.id) }))
            end
          end
        end
        row do
          col(sm: 6) do
            file_field :product_csv, label: "Загрузить из CSV", accept: ".csv", help: "Файл CSV, где первая колонка — SKU. Текущие связи будут заменены."
          end
          col(sm: 6) do
            select :category_ids_input, 
                   Category.all.order(:translated_name).map { |c| ["#{c.translated_name.presence || c.name} (#{c.ikea_id})", c.ikea_id] }, 
                   { label: "Связанные категории", help: "Статья будет отображаться в товарах этих категорий" }, 
                   { multiple: true, data: { ui: "select2" } }
          end
        end
      end

      linked_products = ContentArticleProduct.where(content_article_id: article.id).includes(:product).order(:position)
      if linked_products.any?
        row do
          col(sm: 12) do
            accordion_id = "linked-products-accordion-#{article.id}"
            collapse_id = "linked-products-collapse-#{article.id}"

            static_field :linked_products_list, label: "Привязанные товары (#{linked_products.size})" do
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
                      table linked_products, class: "table table-condensed" do
                        column :product_sku, label: "SKU" do |cap|
                          if cap.product
                            link_to cap.product_sku, Trestle.lookup(:products).path(:show, id: cap.product.id)
                          else
                            cap.product_sku
                          end
                        end
                        column :name, label: "Название" do |cap|
                          name = cap.product&.name_ru || cap.product&.name
                          extra = cap.product&.small_desc_name.to_s.strip
                          extra.present? ? "#{name} — #{extra}" : (name || "—")
                        end
                        column :actions, label: "" do |cap|
                          link_to admin.path(:remove_product, id: article.id, sku: cap.product_sku),
                                  method: :post,
                                  class: "btn btn-xs btn-outline-danger",
                                  data: { confirm: "Удалить связь с этим товаром?", turbo: false } do
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

    concat(content_tag(:script, type: "text/javascript") do
      raw <<-JS.strip_heredoc
        (function() {
          if (window.__contentArticleReloadOnSave) return;
          window.__contentArticleReloadOnSave = true;

          function handleSubmitEnd(event) {
            var form = event.target;
            if (!form || !form.action) return;
            if (!/\\/admin\\/content_articles\\/\\d+$/.test(form.action)) return;
            if (!event.detail || event.detail.success !== true) return;

            // Force full reload to edit page and land on the first tab
            window.location = form.action + "/edit";
          }

          document.addEventListener("turbo:submit-end", handleSubmitEnd);
          document.addEventListener("turbolinks:submit-end", handleSubmitEnd);
        })();
      JS
    end)

    sidebar do
      if article.persisted?
        link_to admin.path(:duplicate, id: article.id),
                class: "btn btn-outline-info btn-block mb-4",
                data: { confirm: "Создать копию этой статьи для редактирования?", turbo: false } do
          content_tag(:i, nil, class: "fa fa-copy") + " Копировать статью"
        end
      end
      
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
      :product_csv,
      :pinned,
      :pinned_position,
      :published_at,
      :active,
      product_skus_input: [],
      category_ids_input: [],
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end
