Trestle.resource(:products, model: Product) do
  menu do
    item :products, icon: "fa fa-cube", priority: 2, label: "Продукты", group: "Catalog"
  end

  routes do
    get :by_category, on: :collection
    get :export_extended_attrs_input, on: :collection
    post :import_extended_attrs, on: :collection
    post :import_bestsellers_csv, on: :collection
    post :import_new_arrivals_csv, on: :collection
    post :import_popular_csv, on: :collection
    post :import_recommended_csv, on: :collection
  end

  scopes do
    scope :all, default: true
    scope :bestsellers, -> { Product.bestsellers }, label: "Хиты продаж"
    scope :new_arrivals, -> { Product.new_arrivals }, label: "Новинки"
    scope :popular, -> { Product.popular }, label: "Популярные"
    scope :recommended, -> { Product.recommended }, label: "Рекомендованные"
  end

  collection do |params|
    products = Product.all
    
    # Стандартный поиск Trestle (параметр q)
    if params[:q].present?
      q = "%#{params[:q]}%"
      products = products.where("sku ILIKE :q OR name ILIKE :q OR name_ru ILIKE :q", q: q)
    end

    # Поиск из "Умной панели" (параметр query)
    if params[:query].present?
      q = "%#{params[:query]}%"
      products = products.where("sku ILIKE :q OR name ILIKE :q OR name_ru ILIKE :q", q: q)
    end
    
    products
  end

  table do
    column :sku, link: true
    column :name
    column :name_ru
    column :category do |product|
      product.category&.name || 'Без категории'
    end
    column :price do |product|
      number_to_currency(product.price, unit: 'Zl', format: '%n %u')
    end
    column :quantity, sortable: true
    column :is_bestseller do |product|
      status_tag(product.is_bestseller? ? 'Да' : 'Нет', 
                 product.is_bestseller? ? :success : :secondary)
    end
    column :is_new do |product|
      status_tag(product.is_new? ? 'Да' : 'Нет', 
                 product.is_new? ? :success : :secondary)
    end
    column :is_popular do |product|
      status_tag(product.is_popular? ? 'Да' : 'Нет', 
                 product.is_popular? ? :success : :secondary)
    end
    column :is_recommended do |product|
      status_tag(product.is_recommended? ? 'Да' : 'Нет', 
                 product.is_recommended? ? :success : :secondary)
    end
    column :created_at, align: :center
    column :updated_at, align: :center
    actions do |toolbar, instance, admin|
      toolbar.edit if admin.actions.include?(:edit)
      toolbar.delete if admin.actions.include?(:destroy)
    end
  end

  hook("resource.index.header") do
    render partial: "trestle/products/smart_search_panel", locals: { admin: admin }
  end

  controller do
    def show
      @product = admin.find_instance(params)
      render "trestle/products/show"
    end

    def by_category
      category_ikea_id = params[:category_id].to_s.strip
      return render(json: []) if category_ikea_id.blank?

      products = Product
        .joins(:categories)
        .where(categories: { ikea_id: category_ikea_id })
        .distinct
        .order(:name)
        .limit(500)

      render json: products.map { |p|
        { sku: p.sku, name: (p.name_ru.presence || p.sku) }
      }
    end

    def export_extended_attrs_input
      scope = Product.where.not(url: [nil, ""]).where("url <> ''")
    
      # Если хочешь выгружать только те, кому реально нужны расширенные атрибуты — оставь этот фильтр:
      scope = scope.where(
        "materials IS NULL OR materials = '' OR care_instructions IS NULL OR care_instructions = '' OR safety_info IS NULL OR safety_info = ''"
      )
    
      items = scope
        .select(:sku, :url)
        .limit(50_000)
        .map { |p| { sku: p.sku, url: p.url } }
    
      json = JSON.pretty_generate({ products: items })
      filename = "products_input_extended_attrs_#{Time.zone.now.strftime('%Y%m%d_%H%M%S')}.json"
      send_data json, filename: filename, type: "application/json"
    end
    
    def import_extended_attrs
      file = params[:file]
      force_full = params[:force_full].to_s == '1'
      unless file.respond_to?(:read)
        flash[:error] = "Не выбран файл."
        return redirect_to admin.path(:index)
      end

      import_path = prepare_import_file(file)
      if import_path.blank?
        flash[:error] = "Не удалось подготовить файл. Для больших файлов используйте JSONL."
        return redirect_to admin.path(:index)
      end

      task = ParserTask.create!(
        task_type: 'extended_attrs_import',
        status: 'pending',
        payload: {
          file_path: import_path,
          original_name: file.original_filename,
          force_full: force_full,
          cursor: 0
        }
      )

      job = ImportExtendedAttributesFromFileJob.perform_later(task_id: task.id)
      task.update!(job_id: job.job_id) if job.respond_to?(:job_id)

      flash[:message] = "Импорт запущен в фоне. Статус смотрите в Управлении парсером."
      redirect_to admin.path(:index)
    end

    def import_bestsellers_csv
      import_product_flag_csv(:is_bestseller, "Хиты продаж")
    end

    def import_new_arrivals_csv
      import_product_flag_csv(:is_new, "Новинки")
    end

    def import_popular_csv
      import_product_flag_csv(:is_popular, "Популярные")
    end

    def import_recommended_csv
      import_product_flag_csv(:is_recommended, "Рекомендованные")
    end

    private

    def import_product_flag_csv(flag, label)
      file = params[:file]
      if file.blank?
        flash[:error] = "Выберите CSV файл."
      else
        begin
          require 'csv'
          skus = []
          CSV.foreach(file.path, headers: false) do |row|
            skus << row[0].to_s.strip if row[0].present?
          end
          
          skus.uniq!
          
          # Reset flag for all products not in the list
          Product.where(flag => true).update_all(flag => false)
          
          # Set flag for products in the list
          updated_count = Product.where(sku: skus).update_all(flag => true)
          
          flash[:notice] = "Импортировано #{updated_count} товаров в список '#{label}'."
        rescue => e
          flash[:error] = "Ошибка импорта: #{e.message}"
        end
      end
      redirect_to admin.path(:index)
    end

    def download_documents(documents, sku)
      Array(documents).filter_map do |doc|
        if doc.is_a?(Hash)
          title = doc["title"] || doc["Tytuł"] || doc["Tytul"] || doc["name"]
          url = doc["url"] || doc["Link"] || doc["href"]
        else
          title = nil
          url = doc.to_s
        end

        next if url.blank?

        local_url = DocumentDownloader.download(url, product_sku: sku)
        { "title" => title, "url" => url, "local_url" => local_url }.compact
      end
    end

    def prepare_import_file(file)
      FileUtils.mkdir_p(Rails.root.join("tmp", "imports"))
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      import_path = Rails.root.join("tmp", "imports", "extended_attrs_#{timestamp}_#{SecureRandom.hex(4)}.jsonl")

      size = file.size.to_i
      sample = file.read(2048).to_s
      file.rewind
      first_char = sample.lstrip[0]

      if first_char == '['
        return nil if size > 20.megabytes
        parsed = JSON.parse(file.read)
        write_jsonl(import_path, parsed)
      elsif first_char == '{' && !sample.include?("\n")
        begin
          parsed = JSON.parse(file.read)
          write_jsonl(import_path, parsed)
        rescue JSON::ParserError
          # Если это большой JSONL с длинными строками — просто копируем как есть
          file.rewind
          File.open(import_path, "wb") { |f| IO.copy_stream(file, f) }
        end
      else
        File.open(import_path, "wb") { |f| IO.copy_stream(file, f) }
      end

      import_path.to_s
    rescue JSON::ParserError
      # На случай некорректного JSON — сохраняем как JSONL, пусть job обработает построчно
      file.rewind
      File.open(import_path, "wb") { |f| IO.copy_stream(file, f) }
      import_path.to_s
    ensure
      file.rewind if file.respond_to?(:rewind)
    end

    def write_jsonl(path, parsed)
      items = if parsed.is_a?(Array)
                parsed
              elsif parsed.is_a?(Hash) && parsed["products"].is_a?(Array)
                parsed["products"]
              elsif parsed.is_a?(Hash)
                [parsed]
              else
                []
              end

      File.open(path, "wb") do |f|
        items.each { |item| f.puts(item.to_json) }
      end
    end
  end

  form do |product|
    tab :basic, label: "Главный баннер" do
      text_field :sku, label: "Артикул (SKU)"
      # text_field :unique_id, label: "Уникальный ID (Unique ID)"
      # text_field :item_no, label: "Номер позиции (Item No)"
      text_field :url, label: "Ссылка (URL)"
      text_field :name, label: "Название (Name)"
      text_field :name_ru, label: "Название RU"
      # text_field :collection, label: "Коллекция (Collection)"
      select :category_id, Category.all.map { |c| [c.translated_name, c.ikea_id] }, { label: "Категория (Category)", include_blank: "Без категории" }
      
      form_group :categories, label: "Дополнительные категории (Additional Categories)" do
        select :category_ids, Category.all.map { |c| [c.translated_name, c.ikea_id] }, { label: "Категории" }, { multiple: true, data: { ui: "select2" } }
      end
    end

    tab :pricing, label: "Цена и наличие" do
      number_field :price, label: "Цена (Price)"
      number_field :quantity, label: "Количество (Quantity)"
      text_field :home_delivery, label: "Доставка на дом (Home Delivery)"
      
      static_field :calculated_duty_info, label: "Таможенная пошлина (BYN)" do
        if product.price && product.weight
          eur_rate = ExchangeRate.fetch_or_create('EUR', Date.today)&.rate_per_unit
          pln_rate = ExchangeRate.fetch_or_create('PLN', Date.today)&.rate_per_unit
          if eur_rate && pln_rate
            price_eur = (product.price * pln_rate / eur_rate).round(2)
            calculation = CustomsDutyService.calculate(price_eur, product.weight, eur_rate)
            "#{calculation[:total_byn]} BYN (Пошлина: #{calculation[:duty_byn]} + Сбор: #{calculation[:fee_byn]})"
          else
            "Курсы валют не найдены"
          end
        else
          "Недостаточно данных для расчета"
        end
      end
    end

    tab :flags, label: "Флаги" do
      check_box :is_bestseller, label: "Хит продаж (Is Bestseller)"
      check_box :is_new, label: "Новинка (Is New)"
      check_box :is_popular, label: "Популярный (Is Popular)"
      check_box :is_recommended, label: "Рекомендованный (Is Recommended)"
      number_field :popularity_score, label: "Оценка популярности (Popularity Score)"
      number_field :views_count, label: "Количество просмотров (Views Count)"
      number_field :sales_count, label: "Количество продаж (Sales Count)"
    end

    tab :delivery, label: "Доставка" do
      select :delivery_type, [['Курьер', 'courier'], ['Самовывоз', 'pickup']], { label: "Тип доставки (Delivery Type)" }
      text_field :delivery_name, label: "Название доставки (Delivery Name)"
      number_field :delivery_cost, label: "Стоимость доставки (Delivery Cost)"
      text_field :delivery_reason, label: "Причина доставки (Delivery Reason)"
    end

    tab :extended, label: "Расширенные данные" do
      row do
        # check_box :is_parcel, label: "Посылка (Is Parcel)" 

        col(sm: 1) { number_field :weight, label: "Вес (Weight)" }
        col(sm: 6) { }
      end
      row do
        col(sm: 4) { text_area :care_instructions, label: "Описание (PL)" }
        col(sm: 8) { text_area :care_instructions_ru, label: "Описание (RU)" }
      end
      row do
        col(sm: 4) { text_area :short_description, label: "Краткое описание (PL)" }
        col(sm: 8) { text_area :short_description_ru, label: "Краткое описание (RU)" }
      end
      row do
        col(sm: 4) { text_area :materials, label: "Материалы (PL)" }
        col(sm: 8) { text_area :materials_ru, label: "Материалы (RU)" }
      end
      row do
        col(sm: 4) { text_area :care_instructions, label: "Инструкции по уходу (PL)" }
        col(sm: 8) { text_area :care_instructions_ru, label: "Инструкции по уходу (RU)" }
      end

      static_field :full_attributes_json, label: "Документы и атрибуты" do
        accordion_id = "product-full-attrs-#{product.id}"
        assembly_collapse_id = "#{accordion_id}-assembly"
        manuals_collapse_id = "#{accordion_id}-manuals"
        json_collapse_id = "#{accordion_id}-json"
        ru_collapse_id = "#{accordion_id}-ru"

        content_tag(:div, class: "accordion", id: accordion_id) do
          concat(
            content_tag(:div, class: "accordion-item") do
              header_id = "#{assembly_collapse_id}-header"
              concat(
                content_tag(:h2, class: "accordion-header", id: header_id) do
                  content_tag(
                    :button,
                    "Инструкции (PDF)",
                    class: "accordion-button collapsed",
                    type: "button",
                    data: { "bs-toggle": "collapse", "bs-target": "##{assembly_collapse_id}" },
                    aria: { expanded: "false", controls: assembly_collapse_id }
                  )
                end
              )
              concat(
                content_tag(
                  :div,
                  id: assembly_collapse_id,
                  class: "accordion-collapse collapse",
                  aria: { labelledby: header_id },
                  data: { "bs-parent": "##{accordion_id}" }
                ) do
                  content_tag(:div, class: "accordion-body") do
                    if product.assembly_documents.is_a?(Array)
                      content_tag(:ul) do
                        product.assembly_documents.map do |doc|
                          url = doc["local_url"].presence || doc["url"]
                          next if url.blank?
                          content_tag(:li) do
                            link_to(url, url, target: "_blank")
                          end
                        end.compact.join.html_safe
                      end
                    else
                      "Инструкции отсутствуют"
                    end
                  end
                end
              )
            end
          )

          concat(
            content_tag(:div, class: "accordion-item") do
              header_id = "#{manuals_collapse_id}-header"
              concat(
                content_tag(:h2, class: "accordion-header", id: header_id) do
                  content_tag(
                    :button,
                    "Руководства (PDF)",
                    class: "accordion-button collapsed",
                    type: "button",
                    data: { "bs-toggle": "collapse", "bs-target": "##{manuals_collapse_id}" },
                    aria: { expanded: "false", controls: manuals_collapse_id }
                  )
                end
              )
              concat(
                content_tag(
                  :div,
                  id: manuals_collapse_id,
                  class: "accordion-collapse collapse",
                  aria: { labelledby: header_id },
                  data: { "bs-parent": "##{accordion_id}" }
                ) do
                  content_tag(:div, class: "accordion-body") do
                    if product.manuals.is_a?(Array)
                      content_tag(:ul) do
                        product.manuals.map do |doc|
                          url = doc["local_url"].presence || doc["url"]
                          next if url.blank?
                          content_tag(:li) do
                            link_to(url, url, target: "_blank")
                          end
                        end.compact.join.html_safe
                      end
                    else
                      "Руководства отсутствуют"
                    end
                  end
                end
              )
            end
          )

          concat(
            content_tag(:div, class: "accordion-item") do
              header_id = "#{json_collapse_id}-header"
              concat(
                content_tag(:h2, class: "accordion-header", id: header_id) do
                  content_tag(
                    :button,
                    "JSON",
                    class: "accordion-button collapsed",
                    type: "button",
                    data: { "bs-toggle": "collapse", "bs-target": "##{json_collapse_id}" },
                    aria: { expanded: "false", controls: json_collapse_id }
                  )
                end
              )
              concat(
                content_tag(
                  :div,
                  id: json_collapse_id,
                  class: "accordion-collapse collapse",
                  aria: { labelledby: header_id },
                  data: { "bs-parent": "##{accordion_id}" }
                ) do
                  content_tag(:div, class: "accordion-body") do
                    if product.full_attributes.present?
                      content_tag(:pre, JSON.pretty_generate(product.full_attributes))
                    else
                      "Нет данных"
                    end
                  end
                end
              )
            end
          )

          concat(
            content_tag(:div, class: "accordion-item") do
              header_id = "#{ru_collapse_id}-header"
              concat(
                content_tag(:h2, class: "accordion-header", id: header_id) do
                  content_tag(
                    :button,
                    "RU",
                    class: "accordion-button collapsed",
                    type: "button",
                    data: { "bs-toggle": "collapse", "bs-target": "##{ru_collapse_id}" },
                    aria: { expanded: "false", controls: ru_collapse_id }
                  )
                end
              )
              concat(
                content_tag(
                  :div,
                  id: ru_collapse_id,
                  class: "accordion-collapse collapse",
                  aria: { labelledby: header_id },
                  data: { "bs-parent": "##{accordion_id}" }
                ) do
                  content_tag(:div, class: "accordion-body") do
                    if product.full_attributes_ru.present?
                      ordered = {
                        "description" => product.full_attributes_ru["description"],
                        "size" => product.full_attributes_ru["size"],
                        "materials" => product.full_attributes_ru["materials"],
                        "instructions" => product.full_attributes_ru["instructions"]
                      }.compact
                      content_tag(:pre, JSON.pretty_generate(ordered))
                    else
                      "Нет данных"
                    end
                  end
                end
              )
            end
          )
        end
      end
    end

    tab :seo, label: "SEO" do
      seo_obj = product.seo_meta || product.build_seo_meta
      fields_for :seo_meta, seo_obj do |seo|
        row do
          col(sm: 12) { seo.text_field :title, label: "SEO Title", help: "Если пусто, будет сгенерировано автоматически" }
        end
        row do
          col(sm: 12) { seo.text_area :description, label: "SEO Description", help: "Если пусто, будет сгенерировано автоматически" }
        end
        row do
          col(sm: 6) { seo.text_field :keywords, label: "SEO Keywords" }
          col(sm: 6) { seo.text_field :robots, label: "SEO Robots", placeholder: "index, follow" }
        end
        row do
          col(sm: 12) { seo.tinymce :seo_text, label: "SEO Текст" }
        end
      end
    end

    tab :tips, label: "Советы" do
      static_field :relevant_tips, label: "Связанные советы" do
        tips = ContentArticle.visible.tips_ideas.relevant_for_product(product)
        if tips.any?
          content_tag(:ul) do
            tips.map do |tip|
              content_tag(:li) do
                link_to(tip.title, Trestle.lookup(:content_articles).path(:show, id: tip.id))
              end
            end.join.html_safe
          end
        else
          "Для этого товара нет специфических советов"
        end
      end
    end
  end

  params do |params|
    params.require(:product).permit(
      :sku, :unique_id, :item_no, :url, :name, :name_ru, :collection, :category_id,
      :price, :quantity, :home_delivery, :weight, :net_weight, :package_volume,
      :package_dimensions, :dimensions, :dimensions_ru, :is_parcel,
      :is_bestseller, :is_new, :is_popular, :is_recommended, :translated, :popularity_score, :views_count, :sales_count,
      :delivery_type, :delivery_name, :delivery_cost, :delivery_reason,
      :short_description, :short_description_ru, :materials, :materials_ru,
      :care_instructions, :care_instructions_ru,
      category_ids: [],
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end

