# frozen_string_literal: true

module Products
  class JsonFileImportService
    Result = Struct.new(:status, :sku, :product_id, :created, :updated, :unchanged, :links_added, keyword_init: true)

    def initialize(replace_category_links: false, logger: Rails.logger)
      @replace_category_links = replace_category_links
      @logger = logger
    end

    def process_item(raw_item)
      item = raw_item.to_h.with_indifferent_access
      sku = item[:sku].to_s.strip
      return Result.new(status: :skipped, sku: nil, created: false, updated: false, unchanged: true, links_added: 0) if sku.blank?

      product = Product.find_or_initialize_by(sku: sku)
      was_new = product.new_record?

      details = (item["Подробная информация о товаре"] || {}).to_h.with_indifferent_access

      assign_core_attributes(product, item, details)
      assign_extended_attributes(product, item, details)

      product_changed = product.new_record? || product.changed?
      product.save! if product_changed

      links_added = sync_categories(product, item)
      cleanup_removed_links(product, item) if @replace_category_links

      status =
        if was_new
          :created
        elsif product_changed || links_added.positive?
          :updated
        else
          :unchanged
        end

      Result.new(
        status: status,
        sku: sku,
        product_id: product.id,
        created: status == :created,
        updated: status == :updated,
        unchanged: status == :unchanged,
        links_added: links_added
      )
    rescue => e
      @logger.error("JsonFileImportService error sku=#{raw_item.is_a?(Hash) ? raw_item['sku'] || raw_item[:sku] : nil}: #{e.class} - #{e.message}")
      @logger.error(e.backtrace.first(10).join("\n")) if e.backtrace
      Result.new(status: :error, sku: raw_item.is_a?(Hash) ? raw_item['sku'] || raw_item[:sku] : nil, created: false, updated: false, unchanged: false, links_added: 0)
    end

    private

    def assign_core_attributes(product, item, details)
      assign_if_supported(product, :sku, item[:sku].to_s.strip)
      assign_if_supported(product, :item_no, normalize_item_no(details["Артикульный номер"]) || item[:sku].to_s.strip)

      main_category_id = primary_category_id(item)
      assign_if_supported(product, :category_id, main_category_id)

      raw_category_id = item[:category_id].to_s.strip.presence
      if raw_category_id.present? && main_category_id.present? && raw_category_id != main_category_id
        @logger.warn("JsonFileImportService category mismatch sku=#{item[:sku]} raw_category_id=#{raw_category_id} effective_category_id=#{main_category_id}")
      end

      assign_if_supported(product, :url, item[:product_url].presence)

      name = item[:name].to_s.strip.presence || extract_name(item, details)
      assign_if_supported(product, :name, name)
      assign_if_supported(product, :name_ru, name)

      small_desc_name = item[:small_desc_name].to_s.strip.presence
      assign_if_supported(product, :small_desc_name, small_desc_name)
      assign_if_supported(product, :small_desc_name_ru, small_desc_name) if product.respond_to?(:small_desc_name_ru=)

      price = normalize_price(item[:price])
      assign_if_supported(product, :price, price) if price.present?

      short_description = item[:short_description].to_s.strip.presence
      assign_if_supported(product, :short_description, short_description)
      assign_if_supported(product, :short_description_ru, short_description)

      content = details["Полное описание"].to_s.strip.presence || normalize_description(details["Описание"])
      assign_if_supported(product, :content, content)
      assign_if_supported(product, :content_ru, content)

      designer = extract_designer(details)
      assign_if_supported(product, :designer, designer)
      assign_if_supported(product, :designer_ru, designer)

      images = normalize_images(item[:images])
      assign_if_supported(product, :images, images) if images.present?

      related_products = normalize_string_array(item[:related_products])
      assign_if_supported(product, :related_products, related_products) if related_products.present?

      variants = normalize_variants(item[:variants])
      assign_if_supported(product, :variants, variants) if variants.present?
    end

    def assign_extended_attributes(product, item, details)
      good_to_know = details["Полезная информация"].to_s.strip.presence
      assign_if_supported(product, :good_to_know, good_to_know)
      assign_if_supported(product, :good_to_know_ru, good_to_know)

      safety_info = details["Безопасность и соответствие требованиям"].to_s.strip.presence
      assign_if_supported(product, :safety_info, safety_info)
      assign_if_supported(product, :safety_info_ru, safety_info)

      materials = normalize_materials(details["Материал и уход"])
      assign_if_supported(product, :materials, materials)
      assign_if_supported(product, :materials_ru, materials)

      care = extract_care_instructions(details["Материал и уход"])
      assign_if_supported(product, :care_instructions, care)
      assign_if_supported(product, :care_instructions_ru, care)

      features = normalize_description(details["Описание"])
      assign_if_supported(product, :features, features)
      assign_if_supported(product, :features_ru, features)

      dimensions_hash, technical_hash = extract_dimensions_and_technical(details)

      if dimensions_hash.present?
        assign_if_supported(product, :dimensions, dimensions_hash.to_json)
        assign_if_supported(product, :dimensions_ru, dimensions_hash.to_json)

        weight = extract_weight_from_dimensions(dimensions_hash)
        assign_if_supported(product, :weight, weight) if weight.present?
      end

      manuals, assembly_documents, videos = extract_link_sets(item, details)
      assign_if_supported(product, :manuals, manuals) if manuals.present?
      assign_if_supported(product, :assembly_documents, assembly_documents) if assembly_documents.present?
      assign_if_supported(product, :videos, videos) if videos.present?

      full_attrs = build_full_attributes(item, details, dimensions_hash, technical_hash)
      assign_if_supported(product, :full_attributes, full_attrs)
      assign_if_supported(product, :full_attributes_ru, full_attrs)
    end

    def sync_categories(product, item)
      category_payloads = category_payloads_from_item(item)
      links_added = 0

      category_payloads.each do |payload|
        category = Category.find_or_initialize_by(ikea_id: payload[:ikea_id])

        if category.new_record?
          category.name = payload[:name].presence || payload[:ikea_id]
          category.translated_name = payload[:name] if category.respond_to?(:translated_name=) && payload[:name].present?
          category.url = payload[:url] if category.respond_to?(:url=) && payload[:url].present?
          category.is_deleted = false if category.respond_to?(:is_deleted=)
          category.save!
        else
          updates = {}
          updates[:name] = payload[:name] if payload[:name].present? && category.name.blank?
          updates[:translated_name] = payload[:name] if category.respond_to?(:translated_name) && payload[:name].present? && category.translated_name.blank?
          updates[:url] = payload[:url] if category.respond_to?(:url) && payload[:url].present? && category.url.blank?
          category.update!(updates) if updates.any?
        end

        link = CategoryProduct.find_or_create_by!(product: product, category_id: payload[:ikea_id])
        links_added += 1 if link.previously_new_record?
      end

      links_added
    end

    def cleanup_removed_links(product, item)
      desired_ids = category_ids_from_item(item)
      CategoryProduct.where(product: product).where.not(category_id: desired_ids).delete_all
    end

    def category_payloads_from_item(item)
      payloads = Array(item[:categories]).filter_map do |entry|
        next unless entry.is_a?(Hash)

        h = entry.with_indifferent_access
        ikea_id = h[:id].to_s.strip
        next if ikea_id.blank?

        {
          ikea_id: ikea_id,
          name: h[:name].to_s.strip.presence,
          url: h[:url].to_s.strip.presence
        }
      end

      if payloads.empty?
        fallback_id = item[:category_id].to_s.strip.presence
        if fallback_id.present?
          payloads << { ikea_id: fallback_id, name: nil, url: nil }
        end
      end

      payloads.uniq { |c| c[:ikea_id] }
    end

    def category_ids_from_item(item)
      ids = category_payloads_from_item(item).map { |payload| payload[:ikea_id].to_s }
      ids.compact.uniq
    end

    def primary_category_id(item)
      ids = category_ids_from_item(item)
      ids.last.presence || item[:category_id].to_s.strip.presence
    end

    def extract_name(item, details)
      explicit = item[:name].to_s.strip.presence || details["Название"].to_s.strip.presence
      return explicit if explicit.present?

      url = item[:product_url].to_s
      slug = url.split("/").reject(&:blank?).last.to_s
      slug = slug.sub(/-\d+\/?$/, '').sub(/-\d+$/, '')
      fallback = slug.tr("-", " ").squish
      fallback.presence || "SKU #{item[:sku]}"
    end

    def extract_designer(details)
      return details["Дизайнер"].to_s.strip if details["Дизайнер"].present?

      description = details["Описание"]
      if description.is_a?(Array)
        last = description.last.to_s.strip
        return last if last.match?(/[A-Za-z]/)
      end

      nil
    end

    def normalize_item_no(value)
      return nil if value.blank?
      value.to_s.gsub(/[^\d]/, "")
    end

    def normalize_price(value)
      return nil if value.blank?
      normalized = value.to_s.gsub(/[^\d,\.]/, "").tr(",", ".")
      return nil if normalized.blank?
      normalized.to_f
    end

    def normalize_images(values)
      Array(values).map(&:to_s).map(&:strip).select { |v| v.start_with?("http://", "https://") }.uniq
    end

    def normalize_string_array(values)
      Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def normalize_variants(values)
      Array(values).map do |value|
        if value.is_a?(Hash)
          value.deep_stringify_keys
        else
          { "value" => value.to_s }
        end
      end
    end

    def normalize_description(value)
      case value
      when Array
        value.map(&:to_s).map(&:strip).reject(&:blank?).join("\n")
      when String
        value.strip.presence
      else
        nil
      end
    end

    def normalize_materials(value)
      case value
      when Hash
        value.map { |k, v| "#{k}: #{v}" }.join("\n").presence
      when String
        value.strip.presence
      else
        nil
      end
    end

    def extract_care_instructions(value)
      return nil unless value.is_a?(Hash)

      care_pairs = value.select { |k, _| k.to_s.match?(/уход|care/i) }
      return nil if care_pairs.empty?

      care_pairs.map { |k, v| "#{k}: #{v}" }.join("\n").presence
    end

    def extract_dimensions_and_technical(details)
      ignored = [
        "Полезная информация",
        "Материал и уход",
        "Безопасность и соответствие требованиям",
        "Сборка и документы",
        "Полное описание",
        "Описание",
        "Артикульный номер",
        "Информация об упаковке",
        "Дизайнер",
        "Название"
      ]

      dimensions = {}
      technical = {}

      details.each do |key, value|
        next if ignored.include?(key.to_s)
        next if value.blank?
        next if value.is_a?(Hash) || value.is_a?(Array)

        if key.to_s.match?(/длина|ширина|высота|вес|диаметр|глубина|объем|объём/i)
          dimensions[key.to_s] = value
        else
          technical[key.to_s] = value
        end
      end

      [dimensions, technical]
    end

    def extract_weight_from_dimensions(dimensions_hash)
      key = dimensions_hash.keys.find { |k| k.to_s.match?(/вес/i) }
      return nil unless key

      dimensions_hash[key].to_s.gsub(",", ".").scan(/(\d+(?:\.\d+)?)/).flatten.first&.to_f
    end

    def extract_link_sets(item, details)
      manuals = normalize_link_array(item[:manuals])
      assembly_documents = normalize_link_array(item[:assembly_documents])
      videos = normalize_link_array(item[:videos])

      assembly_text = details["Сборка и документы"].to_s
      extracted_urls = assembly_text.scan(%r{https?://[^\s]+}).uniq

      if extracted_urls.any? && assembly_documents.blank?
        assembly_documents = extracted_urls.map { |url| { "url" => url } }
      end

      [manuals, assembly_documents, videos]
    end

    def normalize_link_array(values)
      Array(values).filter_map do |value|
        case value
        when Hash
          h = value.with_indifferent_access
          url = h[:url].to_s.strip
          next if url.blank?
          { "title" => h[:title].presence, "url" => url }.compact
        when String
          url = value.to_s.strip
          next if url.blank?
          { "url" => url }
        end
      end
    end

    def build_full_attributes(item, details, dimensions_hash, technical_hash)
      {
        "source" => "json_file",
        "sku" => item[:sku],
        "name" => item[:name],
        "name_ru" => item[:name],
        "small_desc_name" => item[:small_desc_name],
        "price_raw" => item[:price],
        "raw_category_id" => item[:category_id],
        "effective_category_id" => primary_category_id(item),
        "categories" => item[:categories],
        "images" => normalize_images(item[:images]),
        "product_url" => item[:product_url],
        "short_description" => item[:short_description],
        "detailed_info" => details,
        "dimensions_map" => dimensions_hash,
        "technical_map" => technical_hash,
        "related_products" => normalize_string_array(item[:related_products]),
        "variants" => normalize_variants(item[:variants])
      }.compact
    end

    def assign_if_supported(record, attr_name, value)
      return if value.nil?
      return unless record.respond_to?("#{attr_name}=")

      record.public_send("#{attr_name}=", value)
    end
  end
end
