require 'net/http'
require 'uri'

module Products
  class ExtendedAttributesImportService
    def initialize(force_full: false, format: nil, trust_images: false)
      @force_full = force_full
      @format = format
      @trust_images = trust_images
      @image_cache = {}
      @error_logger = Logger.new(Rails.root.join('log', 'import_errors.log'))
      @error_logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime}: #{msg}\n"
      end
    end

    def process_item(item)
      return :skipped unless item.is_a?(Hash)

      item = Products::ImportPayloadAdapter.normalize(item, format: @format)
      import_meta = (item['_import_meta'] || {}).with_indifferent_access

      sku = item['sku'].to_s.strip
      if sku.blank?
        log_error("SKU is blank for item: #{item.inspect.truncate(200)}")
        return :skipped
      end

      product = Product.find_or_initialize_by(sku: sku)
      is_new = product.new_record?

      identity = item['identity'] || {}
      pricing = item['pricing'] || {}
      content = item['content'] || {}
      media = item['media'] || {}
      attributes_data = item['attributes'] || {}
      connections = item['connections'] || {}
      raw_data_dump = item['raw_data_dump'] || {}

      assign_product_attributes(product, identity, pricing, content, connections, attributes_data)
      handle_images(product, media['images'], trusted: import_meta['trusted_images'] || @trust_images)
      assign_extended_attributes(product, attributes_data, content, raw_data_dump)

      if product.save
        handle_categories(product, content['categories'])
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
      Rails.logger.error("[Import] #{message}")
      @error_logger.error(message)
    end

    def assign_product_attributes(product, identity, pricing, content, connections, attributes_data)
      assign_if_present(product, :name, identity['name'])
      assign_if_present(product, :name_ru, identity['name_ru'] || identity['name'])
      assign_if_present(product, :item_no, identity['article_number'].to_s.gsub('.', '').presence)
      assign_if_present(product, :url, identity['product_url'])
      assign_if_present(product, :price, pricing['price'])
      assign_if_present(product, :category_id, identity['category_id'])

      assign_if_present(product, :short_description, content['short_description'])
      assign_if_present(product, :short_description_ru, content['short_description'])
      assign_if_present(product, :content, content['full_description'])
      assign_if_present(product, :content_ru, content['full_description'])
      assign_if_present(product, :designer, content['designer'])
      assign_if_present(product, :designer_ru, content['designer'])

      assign_if_present(product, :features, normalize_text_blob(attributes_data['features'] || content['features']))
      assign_if_present(product, :features_ru, normalize_text_blob(attributes_data['features'] || content['features']))
      assign_if_present(product, :good_to_know, normalize_text_blob(attributes_data.dig('additional_info', 'good_to_know')))
      assign_if_present(product, :good_to_know_ru, normalize_text_blob(attributes_data.dig('additional_info', 'good_to_know')))
      assign_if_present(product, :safety_info, normalize_text_blob(attributes_data.dig('additional_info', 'safety_info')))
      assign_if_present(product, :safety_info_ru, normalize_text_blob(attributes_data.dig('additional_info', 'safety_info')))

      if connections['related_products'].present?
        product.related_products = connections['related_products']
      end
      if connections['variants'].present?
        product.variants = connections['variants']
      end

      if attributes_data['manuals'].present?
        product.manuals = attributes_data['manuals']
      end
      if attributes_data.dig('additional_info', 'assembly_documents').present?
        product.assembly_documents = attributes_data.dig('additional_info', 'assembly_documents')
      end
      if attributes_data['packaging'].present?
        product.packaging = attributes_data['packaging']
      elsif attributes_data.dig('additional_info', 'packaging').present?
        product.packaging = attributes_data.dig('additional_info', 'packaging')
      end
    end

    def assign_if_present(record, attribute, value)
      return if value.blank?
      record.public_send("#{attribute}=", value)
    end

    def normalize_text_blob(value)
      case value
      when Array
        value.map(&:to_s).map(&:strip).reject(&:blank?).join("\n")
      when Hash
        value.map { |k, v| "#{k}: #{v}" }.join("\n")
      else
        value.to_s.strip.presence
      end
    end

    def handle_images(product, new_images, trusted: false)
      return if new_images.blank?

      valid_new_images = if trusted
        Array(new_images).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      else
        Array(new_images).select { |url| image_working?(url) }
      end

      if valid_new_images.any?
        product.images = valid_new_images
        product.local_images = [] if product.respond_to?(:local_images)
      end
    end

    def image_working?(url)
      return false if url.blank?
      return @image_cache[url] if @image_cache.key?(url)

      begin
        uri = URI.parse(url)
        return false unless uri.is_a?(URI::HTTP)

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
      categories_data = Array(categories_data).map(&:to_h).map(&:with_indifferent_access)

      if product.category_id.present? && categories_data.none? { |c| c['id'].to_s == product.category_id.to_s }
        categories_data << { 'id' => product.category_id }
      end

      return if categories_data.blank?

      categories_data.each do |cat_data|
        ikea_id = cat_data['id']
        next if ikea_id.blank?

        category = Category.find_or_initialize_by(ikea_id: ikea_id)
        if category.new_record?
          if cat_data['name'].present?
            category.name = cat_data['name']
            category.url = cat_data['url']
            unless category.save
              log_error("Failed to save new category #{ikea_id} for product #{product.sku}: #{category.errors.full_messages.join(', ')}")
            end
          else
            log_error("Skipping category creation #{ikea_id} for product #{product.sku}: Name is blank")
            next
          end
        elsif category.name.blank? && cat_data['name'].present?
          unless category.update(name: cat_data['name'])
            log_error("Failed to update category #{ikea_id} name for product #{product.sku}: #{category.errors.full_messages.join(', ')}")
          end
        end

        CategoryProduct.find_or_create_by(product: product, category_id: ikea_id.to_s)
      end
    end

    def assign_extended_attributes(product, attributes_data, content, raw_data_dump)
      full_attrs = {
        'dimensions' => attributes_data['dimensions'],
        'technical' => attributes_data['technical'],
        'materials' => attributes_data['materials'],
        'care_instructions' => attributes_data['care_instructions'],
        'additional_info' => attributes_data['additional_info'],
        'description' => content['full_description'],
        'raw_dump' => raw_data_dump
      }

      product.full_attributes = full_attrs
      product.full_attributes_ru = full_attrs

      if attributes_data['materials'].is_a?(Hash)
        product.materials = attributes_data['materials'].map { |k, v| "#{k}: #{v}" }.join("\n")
        product.materials_ru = product.materials
      elsif attributes_data['materials'].present?
        product.materials = normalize_text_blob(attributes_data['materials'])
        product.materials_ru = product.materials
      end

      if attributes_data['care_instructions'].present?
        care_value = normalize_text_blob(attributes_data['care_instructions'])
        product.care_instructions = care_value
        product.care_instructions_ru = care_value
      end

      if attributes_data['dimensions'].present?
        dim_json = attributes_data['dimensions'].to_json
        product.dimensions = dim_json
        product.dimensions_ru = dim_json
      end

      weight_val = extract_weight(attributes_data.dig('dimensions', 'weight') || attributes_data.dig('dimensions', 'Вес'))
      product.weight = weight_val if weight_val
    end

    def extract_weight(weight_str)
      return nil if weight_str.blank?
      weight_str.to_s.gsub(',', '.').scan(/(\d+(?:\.\d+)?)/).flatten.first&.to_f
    end
  end
end
