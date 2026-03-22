require 'net/http'
require 'uri'

module Products
  class ExtendedAttributesImportService
    def initialize(force_full: false)
      @force_full = force_full
      @image_cache = {}
      @error_logger = Logger.new(Rails.root.join('log', 'import_errors.log'))
      @error_logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime}: #{msg}\n"
      end
    end

    def process_item(item)
      return :skipped unless item.is_a?(Hash)

      sku = item["sku"].to_s.strip
      if sku.blank?
        log_error("SKU is blank for item: #{item.inspect.truncate(200)}")
        return :skipped
      end

      # 1. Находим или создаем продукт
      product = Product.find_or_initialize_by(sku: sku)
      is_new = product.new_record?

      # Извлекаем основные данные из новой структуры
      identity = item["identity"] || {}
      pricing = item["pricing"] || {}
      content = item["content"] || {}
      media = item["media"] || {}
      attributes_data = item["attributes"] || {}
      connections = item["connections"] || {}
      raw_data_dump = item["raw_data_dump"] || {}

      # 2. Обновляем основные атрибуты
      assign_product_attributes(product, identity, pricing, content, connections)

      # 3. Обрабатываем изображения
      handle_images(product, media["images"])

      # 4. Обрабатываем расширенные атрибуты (присваиваем атрибуты перед сохранением)
      assign_extended_attributes(product, attributes_data, content, raw_data_dump)

      # 5. Сохраняем продукт
      # Используем save!, чтобы сработали все коллбеки (включая переиндексацию фильтров)
      if product.save
        # 6. Обрабатываем категории (нужен ID продукта для связей)
        handle_categories(product, content["categories"])
        is_new ? :created : :updated
      else
        log_error("Validation failed for product #{sku}: #{product.errors.full_messages.join(', ')}")
        :error
      end
    rescue => e
      log_error("Unexpected error for sku=#{sku}: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      :error
    end

    private

    def log_error(message)
      # Дублируем в стандартный лог и в наш специальный лог ошибок импорта
      Rails.logger.error("[Import] #{message}")
      @error_logger.error(message)
    end

    def assign_product_attributes(product, identity, pricing, content, connections)
      product.name = identity["name"] if identity["name"].present?
      # article_number в IKEA часто с точками (306.128.24), в базе храним без (30612824)
      product.item_no = identity["article_number"].to_s.gsub('.', '') if identity["article_number"].present?
      product.url = identity["product_url"] if identity["product_url"].present?
      product.price = pricing["price"] if pricing["price"].present?
      product.category_id = identity["category_id"] if identity["category_id"].present?
      
      # Описания и дизайнеры (предполагаем, что в JSON данные на русском или языке оригинала)
      product.short_description = content["short_description"] if content["short_description"].present?
      product.short_description_ru = content["short_description"] if content["short_description"].present?
      product.content_ru = content["full_description"] if content["full_description"].present?
      product.designer = content["designer"] if content["designer"].present?
      product.designer_ru = content["designer"] if content["designer"].present?
      
      # Связи
      product.related_products = connections["related_products"] if connections["related_products"].present?
      product.variants = connections["variants"] if connections["variants"].present?
    end

    def handle_images(product, new_images)
      return if new_images.blank?

      # Проверяем новые изображения на работоспособность (HEAD запрос)
      valid_new_images = new_images.select { |url| image_working?(url) }
      
      if valid_new_images.any?
        # Если в JSON есть рабочие картинки, заменяем ими старые
        # "удалить старые" - это происходит при присваивании нового массива
        product.images = valid_new_images
        # Сбрасываем локальные изображения, так как ссылки обновились
        product.local_images = [] if product.respond_to?(:local_images)
      end
    end

    def image_working?(url)
      return false if url.blank?
      
      return @image_cache[url] if @image_cache.key?(url)

      begin
        uri = URI.parse(url)
        return false unless uri.is_a?(URI::HTTP)

        # Проверяем доступность ссылки (код 2xx)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 5) do |http|
          http.head(uri.path.presence || '/', { 'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' })
        end
        @image_cache[url] = (200..299).cover?(response.code.to_i)
      rescue => e
        Rails.logger.debug("[Import] Image check failed for #{url}: #{e.message}")
        @image_cache[url] = false
      end
    end

    def handle_categories(product, categories_data)
      # Превращаем в массив и делаем копию, чтобы не менять исходные данные
      categories_data = Array(categories_data).map(&:to_h).map(&:with_indifferent_access)
      
      # Добавляем основную категорию из identity, если ее нет в общем списке
      if product.category_id.present? && categories_data.none? { |c| c["id"].to_s == product.category_id.to_s }
        categories_data << { "id" => product.category_id }
      end

      return if categories_data.blank?

      categories_data.each do |cat_data|
        ikea_id = cat_data["id"]
        next if ikea_id.blank?

        category = Category.find_or_initialize_by(ikea_id: ikea_id)
        if category.new_record?
          # Создаем категорию только если есть имя (обязательное поле)
          if cat_data["name"].present?
            category.name = cat_data["name"]
            category.url = cat_data["url"]
            unless category.save
              log_error("Failed to save new category #{ikea_id} for product #{product.sku}: #{category.errors.full_messages.join(', ')}")
            end
          else
            log_error("Skipping category creation #{ikea_id} for product #{product.sku}: Name is blank")
            next
          end
        elsif category.name.blank? && cat_data["name"].present?
          unless category.update(name: cat_data["name"])
            log_error("Failed to update category #{ikea_id} name for product #{product.sku}: #{category.errors.full_messages.join(', ')}")
          end
        end

        # Создаем связь между товаром и категорией (продукт может быть в нескольких)
        CategoryProduct.find_or_create_by(product: product, category_id: ikea_id.to_s)
      end
    end

    def assign_extended_attributes(product, attributes_data, content, raw_data_dump)
      # Формируем структуру для full_attributes (JSONB)
      full_attrs = {
        "dimensions" => attributes_data["dimensions"],
        "technical" => attributes_data["technical"],
        "materials" => attributes_data["materials"],
        "care_instructions" => attributes_data["care_instructions"],
        "additional_info" => attributes_data["additional_info"],
        "description" => content["full_description"],
        "raw_dump" => raw_data_dump
      }

      product.full_attributes = full_attrs
      product.full_attributes_ru = full_attrs
      
      # Маппинг материалов в текстовое поле для совместимости и поиска
      if attributes_data["materials"].is_a?(Hash)
        product.materials_ru = attributes_data["materials"].map { |k, v| "#{k}: #{v}" }.join("\n")
      elsif attributes_data["materials"].present?
        product.materials_ru = attributes_data["materials"].to_s
      end

      product.care_instructions_ru = attributes_data["care_instructions"] if attributes_data["care_instructions"].present?
      
      # Размеры (сохраняем как JSON строку в поле dimensions и text в dimensions_ru)
      if attributes_data["dimensions"].present?
        dim_json = attributes_data["dimensions"].to_json
        product.dimensions = dim_json
        product.dimensions_ru = dim_json
      end
      
      # Извлекаем вес из данных о размерах
      weight_val = extract_weight(attributes_data.dig("dimensions", "weight"))
      product.weight = weight_val if weight_val
    end

    def extract_weight(weight_str)
      return nil if weight_str.blank?
      # "1.5 кг" -> 1.5
      weight_str.to_s.gsub(',', '.').scan(/(\d+(\.\d+)?)/).flatten.first&.to_f
    end
  end
end
