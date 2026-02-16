Trestle.resource(:products, model: Product) do
  menu do
    item :products, icon: "fa fa-cube", priority: 2, label: "Продукты", group: "Catalog"
  end

  routes do
    get :by_category, on: :collection
    get :export_extended_attrs_input, on: :collection
    post :import_extended_attrs, on: :collection
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
    column :is_popular do |product|
      status_tag(product.is_popular? ? 'Да' : 'Нет', 
                 product.is_popular? ? :success : :secondary)
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
      unless file.respond_to?(:read)
        flash[:error] = "Не выбран файл."
        return redirect_to admin.path(:index)
      end

      raw = file.read
      lines = raw.split("\n")
      
      updated = 0
      skipped = 0
      errors = 0

      lines.each do |line|
        next if line.blank?
        begin
          item = JSON.parse(line)
        rescue JSON::ParserError
          errors += 1
          next
        end

        sku = item["sku"].to_s.strip
        if sku.blank?
          skipped += 1
          next
        end

        product = Product.find_by(sku: sku)
        unless product
          skipped += 1
          next
        end

        # Собираем все атрибуты
        raw_attributes = item["attributes"] || {}
        
        # Маппинг известных полей
        mapped_attrs = {}
        
        # 1. Описание (Opis) -> short_description
        opis = item["short_description"] || raw_attributes["Opis"]
        if opis.is_a?(Array)
          mapped_attrs["short_description"] = opis.join("\n")
        elsif opis.is_a?(String)
          mapped_attrs["short_description"] = opis
        end

        # 2. Материалы и уход
        mat_and_care = raw_attributes["Materiały i pielęgnacja"] || {}
        if mat_and_care.is_a?(Hash)
          materials = mat_and_care["Materiały"]
          if materials.is_a?(Hash)
            mapped_attrs["materials"] = materials.map { |k, v| "#{k}: #{v}" }.join("\n")
          elsif materials.is_a?(String)
            mapped_attrs["materials"] = materials
          end
          
          care = mat_and_care["Pielęgnacja"]
          if care.is_a?(Hash)
            mapped_attrs["care_instructions"] = care.map do |k, v|
              vals = v.is_a?(Array) ? v.join(", ") : v
              "#{k}: #{vals}"
            end.join("\n")
          elsif care.is_a?(Array)
            mapped_attrs["care_instructions"] = care.join("\n")
          elsif care.is_a?(String)
            mapped_attrs["care_instructions"] = care
          end
        end

        # 3. Безопасность
        mapped_attrs["safety_info"] = raw_attributes["Bezpieczeństwo i zgodność z przepisami"] if raw_attributes["Bezpieczeństwo i zgodność z przepisami"]

        # 4. Хорошо знать
        mapped_attrs["good_to_know"] = raw_attributes["Dobrze wiedzieć"] if raw_attributes["Dobrze wiedzieć"]

        # 5. Дизайнер
        mapped_attrs["designer"] = raw_attributes["Projektant"] if raw_attributes["Projektant"]

        # 6. Документы для сборки
        if raw_attributes["Montaż i dokumenty"].is_a?(Array)
          mapped_attrs["assembly_documents"] = raw_attributes["Montaż i dokumenty"].map do |doc|
            title = doc["Tytuł"] || doc["Tytuл"]
            url = doc["Link"]
            # Загружаем документ локально через прокси
            local_url = DocumentDownloader.download(url, product_sku: sku)
            { "title" => title, "url" => local_url || url }
          end
        end

        # 7. Размеры (все что с cm, kg, inch)
        dimensions_data = {}
        # Ищем размеры в основном словаре атрибутов
        dimension_keys = raw_attributes.keys.select { |k| k =~ /Szerokość|Głębokość|Wysokość|Długość|Waga|Obciążenie|Siedzisko|Łóżko/ }
        dimension_keys.each { |k| dimensions_data[k] = raw_attributes[k] }
        
        # Также проверяем внутри Opakowanie -> Szczegóły (там часто лежат размеры упаковок)
        if raw_attributes["Opakowanie"].is_a?(Hash) && raw_attributes["Opakowanie"]["Szczegóły"].is_a?(Array)
          raw_attributes["Opakowanie"]["Szczegóły"].each_with_index do |pkg, idx|
            pkg.each do |pk, pv|
              next if pk == "Paczka(i)"
              dimensions_data["Упаковка #{idx+1} #{pk}"] = pv
            end
          end
        end

        mapped_attrs["dimensions"] = dimensions_data.to_json if dimensions_data.present?

        # Перевод размеров
        if dimensions_data.present?
          translated_dimensions = {}
          dimensions_data.each do |k, v|
            # Если ключ содержит "Упаковка X", переводим только польскую часть
            if k =~ /^(Упаковка \d+)\s+(.+)$/
              prefix = $1
              polish_part = $2
              translated_part = TranslationService.translate(polish_part)
              translated_key = "#{prefix} #{translated_part}"
            else
              translated_key = TranslationService.translate(k)
            end
            translated_dimensions[translated_key] = v
          end
          mapped_attrs["dimensions_ru"] = translated_dimensions.to_json
        end

        # 8. Упаковка
        mapped_attrs["packaging"] = raw_attributes["Opakowanie"] if raw_attributes["Opakowanie"]

        # 9. Все атрибуты в JSONB
        mapped_attrs["full_attributes"] = raw_attributes

        # Перевод на русский
        translated_attrs = {}
        mapped_attrs.each do |key, value|
          next if %w[assembly_documents dimensions dimensions_ru packaging full_attributes care_instructions].include?(key)
          next if value.blank?
          
          # Переводим только если это строка (контент атрибута)
          if value.is_a?(String)
            begin
              translated_attrs["#{key}_ru"] = TranslationService.translate(value)
            rescue => e
              Rails.logger.error("[TRESTLE] Translation error for #{sku} field #{key}: #{e.message}")
            end
          end
        end

        # Инструкции по уходу (не переводим, оставляем как есть)
        translated_attrs["care_instructions_ru"] = mapped_attrs["care_instructions"] if mapped_attrs["care_instructions"]

        # Размеры переводим всегда (ключи)
        if dimensions_data.present?
          translated_dimensions = {}
          dimensions_data.each do |k, v|
            # Если ключ содержит "Упаковка X", переводим только польскую часть
            if k =~ /^(Упаковка \d+)\s+(.+)$/
              prefix = $1
              polish_part = $2.strip
              # Принудительно используем MyMemory для коротких слов
              begin
                translated_part = TranslationService.translate_with_my_memory(polish_part)
              rescue
                translated_part = TranslationService.translate(polish_part)
              end
              translated_key = "#{prefix} #{translated_part}"
            else
              translated_key = TranslationService.translate(k)
            end
            translated_dimensions[translated_key] = v
          end
          mapped_attrs["dimensions_ru"] = translated_dimensions.to_json
        end

        begin
          # Объединяем все атрибуты и переводы
          final_attrs = mapped_attrs.merge(translated_attrs)
          
          # Принудительно обновляем колонки, минуя dirty tracking Rails
          product.update_columns(final_attrs.slice("dimensions_ru", "short_description_ru", "materials_ru", "care_instructions_ru", "full_attributes", "dimensions"))
          updated += 1
        rescue => e
          Rails.logger.error("[TRESTLE] import_extended_attrs sku=#{sku} error=#{e.class}: #{e.message}")
          errors += 1
        end
      end

      flash[:message] = "Импорт завершен: обновлено=#{updated}, пропущено=#{skipped}, ошибок=#{errors}"
      redirect_to admin.path(:index)
    end    
  end

  form do |product|
    tab :basic, label: "Основная информация" do
      text_field :sku, label: "Артикул (SKU)"
      text_field :unique_id, label: "Уникальный ID (Unique ID)"
      text_field :item_no, label: "Номер позиции (Item No)"
      text_field :url, label: "Ссылка (URL)"
      text_field :name, label: "Название (Name)"
      text_field :name_ru, label: "Название RU (Name RU)"
      text_field :collection, label: "Коллекция (Collection)"
      select :category_id, Category.all.map { |c| [c.name, c.ikea_id] }, { label: "Категория (Category)", include_blank: "Без категории" }
      
      form_group :categories, label: "Дополнительные категории (Additional Categories)" do
        select :category_ids, Category.all.map { |c| [c.name, c.ikea_id] }, { label: "Категории" }, { multiple: true, data: { ui: "select2" } }
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

    tab :specs, label: "Характеристики" do
      number_field :weight, label: "Вес (Weight)"
      number_field :net_weight, label: "Чистый вес (Net Weight)"
      number_field :package_volume, label: "Объем упаковки (Package Volume)"
      text_field :package_dimensions, label: "Размеры упаковки (Package Dimensions)"
      text_field :dimensions, label: "Размеры (Dimensions)"
      text_field :dimensions_ru, label: "Размеры RU (Dimensions RU)"
      check_box :is_parcel, label: "Посылка (Is Parcel)"
    end

    tab :flags, label: "Флаги" do
      check_box :is_bestseller, label: "Хит продаж (Is Bestseller)"
      check_box :is_popular, label: "Популярный (Is Popular)"
      check_box :translated, label: "Переведено (Translated)"
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
        col(sm: 6) { text_area :short_description, label: "Описание (PL)" }
        col(sm: 6) { text_area :short_description_ru, label: "Описание (RU)" }
      end
      row do
        col(sm: 6) { text_area :materials, label: "Материалы (PL)" }
        col(sm: 6) { text_area :materials_ru, label: "Материалы (RU)" }
      end
      row do
        col(sm: 6) { text_area :care_instructions, label: "Инструкции по уходу (PL)" }
        col(sm: 6) { text_area :care_instructions_ru, label: "Инструкции по уходу (RU)" }
      end

      static_field :assembly_documents, label: "Инструкции (PDF)" do
        if product.assembly_documents.is_a?(Array)
          content_tag(:ul) do
            product.assembly_documents.map do |doc|
              next if doc["url"].blank?
              content_tag(:li) do
                link_to(doc["url"], doc["url"], target: "_blank")
              end
            end.compact.join.html_safe
          end
        else
          "Инструкции отсутствуют"
        end
      end

      static_field :full_attributes_json, label: "Все атрибуты (JSON)" do
        content_tag(:pre, JSON.pretty_generate(product.full_attributes)) if product.full_attributes.present?
      end
    end
  end

end

