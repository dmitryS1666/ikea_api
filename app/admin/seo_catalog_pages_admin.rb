# frozen_string_literal: true

Trestle.resource(:seo_catalog_pages, model: SeoCatalogPage) do
  menu do
    item :seo_catalog_pages, icon: "fa fa-search", group: :catalog, priority: 8, label: "SEO-страницы каталога"
  end

  routes do
    get :preview_products, on: :member
    post :generate_snapshot, on: :member
  end

  scopes do
    scope :all, default: true, label: "Все"
    scope :draft, -> { SeoCatalogPage.draft }, label: "Черновики"
    scope :published, -> { SeoCatalogPage.published }, label: "Опубликовано"
    scope :archived, -> { SeoCatalogPage.archived }, label: "Архив"
    scope :sitemap, -> { SeoCatalogPage.for_sitemap }, label: "В sitemap"
    scope :empty, -> { SeoCatalogPage.where(products_count: 0) }, label: "Без товаров"
  end

  collection do |params|
    pages = SeoCatalogPage.ordered

    if params[:q].present?
      q = "%#{params[:q]}%"
      pages = pages.where(
        "slug ILIKE :q OR title ILIKE :q OR h1 ILIKE :q OR meta_title ILIKE :q",
        q: q
      )
    end

    pages
  end

  table do
    column :position, align: :center
    column :title, link: true
    column :slug
    column :status do |page|
      status_tag(
        SeoCatalogPage.human_status(page.status),
        page.published? ? :success : (page.archived? ? :secondary : :warning)
      )
    end
    column :indexable do |page|
      status_tag(page.indexable? ? "Да" : "Нет", page.indexable? ? :success : :danger)
    end
    column :products_count, align: :center do |page|
      if page.products_count.to_i.zero?
        status_tag("0", :danger)
      else
        page.products_count
      end
    end
    column :last_generated_at, align: :center
    column :frontend, label: "Frontend" do |page|
      link_to page.path, page.frontend_url, target: "_blank", rel: "noopener"
    end
    column :actions, label: "Действия" do |page|
      safe_join([
        link_to("Preview", admin.path(:preview_products, id: page.id), class: "btn btn-xs btn-outline-info"),
        " ",
        link_to(
          "Generate",
          admin.path(:generate_snapshot, id: page.id),
          method: :post,
          class: "btn btn-xs btn-outline-primary",
          data: { turbo: false }
        )
      ])
    end
    actions
  end

  form do |page|
    tab :main, label: "Основное" do
      if page.persisted? && page.products_count.to_i.zero?
        row do
          col(sm: 12) do
            content_tag(:div, "В подборке нет товаров. Для SEO такая страница будет noindex / не должна попадать в sitemap.", class: "alert alert-warning")
          end
        end
      end

      row do
        col(sm: 6) { text_field :title, label: "Внутреннее название" }
        col(sm: 6) { text_field :slug, required: true, label: "Slug", help: "URL-safe: latin, digits, dash. Пример: divany-do-1000-byn" }
      end

      row do
        col(sm: 12) { text_field :h1, label: "H1" }
      end

      row do
        col(sm: 6) { select :status, SeoCatalogPage.status_select_options, label: "Статус" }
        col(sm: 3) { check_box :indexable, label: "Indexable" }
        col(sm: 3) { number_field :position, label: "Позиция" }
      end

      row do
        col(sm: 12) { text_field :canonical_path, label: "Canonical path", help: "Если пусто — заполнится как /catalog/seo/<slug>" }
      end
    end

    tab :seo, label: "SEO" do
      row do
        col(sm: 12) { text_field :meta_title, label: "Meta title", help: "Рекомендовано до #{SeoCatalogPage::META_TITLE_MAX_LENGTH} символов" }
      end
      row do
        col(sm: 12) { text_area :meta_description, rows: 3, label: "Meta description", help: "Рекомендовано до #{SeoCatalogPage::META_DESCRIPTION_MAX_LENGTH} символов" }
      end
      row do
        col(sm: 12) { tinymce :seo_text, label: "SEO-текст" }
      end
    end

    tab :filters, label: "Фильтры / подборка" do
      row do
        col(sm: 12) do
          content_tag(:div, class: "alert alert-info") do
            safe_join([
              content_tag(:strong, "filter_config — источник истины для генерации подборки."),
              tag.br,
              "Категории указываются по ikea_id. Фильтры — по параметрам витрины/ProductFilterValue, например f-colors, f-materials. Также поддержаны алиасы color/material/size."
            ])
          end
        end
      end

      row do
        col(sm: 12) do
          text_area :filter_config_json_input,
                    rows: 18,
                    label: "filter_config JSON",
                    help: "Пример: {\"category_ids\":[\"fb001\"],\"max_price\":1000,\"filters\":{\"f-colors\":[\"white\"]},\"only_available\":true,\"sort\":\"popular\",\"limit\":60}"
        end
      end
    end

    sidebar do
      form_group :snapshot, label: "Подборка" do
        static_field :products_count, label: "Товаров"
        static_field :filters_count, label: "Фильтров" do |page|
          page.filters_snapshot_for_api.size
        end
        static_field :last_generated_at, label: "Последняя генерация"
        static_field :last_products_updated_at, label: "Последнее обновление товаров"

        if page.persisted?
          safe_join([
            link_to("Preview товаров", admin.path(:preview_products, id: page.id), class: "btn btn-outline-info btn-block mb-2"),
            link_to(
              "Сгенерировать snapshot товаров и фильтров",
              admin.path(:generate_snapshot, id: page.id),
              method: :post,
              class: "btn btn-primary btn-block mb-2",
              data: { turbo: false }
            ),
            link_to("Открыть frontend", page.frontend_url, target: "_blank", rel: "noopener", class: "btn btn-outline-secondary btn-block")
          ])
        else
          content_tag(:div, "Сначала сохраните страницу, затем будет доступен preview/generate.", class: "text-muted")
        end
      end

      form_group :meta, label: "Служебное" do
        static_field :created_at, label: "Создано"
        static_field :updated_at, label: "Изменено"
        static_field :published_at, label: "Опубликовано"
      end
    end
  end

  controller do
    def preview_products
      @seo_catalog_page = admin.find_instance(params)
      @result = SeoCatalogPages::GenerateSnapshotService.new(@seo_catalog_page, persist: false).preview
      render "trestle/seo_catalog_pages/preview"
    rescue StandardError => e
      Rails.logger.error("SeoCatalogPages preview failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      flash[:error] = "Не удалось собрать preview: #{e.message}"
      redirect_to admin.path(:edit, id: params[:id])
    end

    def generate_snapshot
      page = admin.find_instance(params)
      result = SeoCatalogPages::GenerateSnapshotService.call(page)

      if result.products_count.zero?
        flash[:warning] = "Snapshot товаров и фильтров сгенерирован, но товаров нет. Страница оставлена, indexable установлен в false."
      else
        flash[:message] = "Snapshot сгенерирован: #{result.products_count} товаров, #{result.filters_snapshot.size} фильтров."
      end

      redirect_to admin.path(:edit, id: page.id)
    rescue StandardError => e
      Rails.logger.error("SeoCatalogPages generate failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      flash[:error] = "Не удалось сгенерировать snapshot: #{e.message}"
      redirect_to admin.path(:edit, id: params[:id])
    end
  end

  params do |params|
    params.require(:seo_catalog_page).permit(
      :slug,
      :title,
      :h1,
      :meta_title,
      :meta_description,
      :seo_text,
      :canonical_path,
      :status,
      :indexable,
      :position,
      :filter_config_json_input,
      :published_at
    )
  end
end
