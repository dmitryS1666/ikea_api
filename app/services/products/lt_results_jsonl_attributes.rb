# frozen_string_literal: true

# Маппинг строки результатов парсинга LT (формат JSONL / JsonFileImportService) в атрибуты Product.
# Совпадает со схемой с ключом "Подробная информация о товаре" и русскими подписями полей.
module Products
  class LtResultsJsonlAttributes
    DETAIL_IGNORED_FOR_FLAT = [
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
    ].freeze

    SIGNATURE_KEYS = %w[sku price category_id categories images product_url short_description].freeze

    class << self
      def results_jsonl_row?(raw)
        return false unless raw.is_a?(Hash)

        h = raw.stringify_keys
        SIGNATURE_KEYS.count { |k| h.key?(k) } >= 5 && h.key?("Подробная информация о товаре")
      end

      # Хэш для product.update! — без цены (цену и остаток подмешивает PL в ExtendedAttributesFetchService).
      def to_product_attributes(product, raw_row, trust_images: false)
        new(product, raw_row, trust_images: trust_images).to_attributes
      end     
    end

    def initialize(product, raw_row, trust_images: false)
      @product = product
      @item = raw_row.to_h.stringify_keys
      @details = (@item["Подробная информация о товаре"] || {}).to_h.stringify_keys
      @trust_images = trust_images
    end

    def to_attributes
      attrs = {}
      assign_identity(attrs)
      assign_from_details(attrs)
      assign_media(attrs) if @trust_images
      assign_dimensions_weight_packaging(attrs)
      assign_full_attributes_blob(attrs)
      attrs.compact_blank
    end

    private

    attr_reader :product, :item, :details

    def assign_identity(attrs)
      name = item["name"].to_s.strip.presence || extract_name_from_details
      attrs[:name] = name if name.present?

      sdn = item["small_desc_name"].to_s.strip.presence
      attrs[:small_desc_name] = sdn if sdn.present?
      if product.respond_to?(:small_desc_name_ru=) && sdn.present?
        attrs[:small_desc_name_ru] = sdn
      end

      url = item["product_url"].to_s.strip.presence
      attrs[:url] = url if url.present?

      item_no = normalize_item_no(details["Артикульный номер"]) || item["sku"].to_s.gsub(/\D/, "").presence
      attrs[:item_no] = item_no if item_no.present?

      short = item["short_description"].to_s.strip.presence
      if short.present?
        attrs[:short_description] = short
        attrs[:short_description_ru] = short
      end

      content = details["Полное описание"].to_s.strip.presence || normalize_description(details["Описание"])
      if content.present?
        attrs[:content] = content
        attrs[:content_ru] = content
      end

      designer = extract_designer
      if designer.present?
        attrs[:designer] = designer
        attrs[:designer_ru] = designer
      end
    end

    def assign_from_details(attrs)
      g = details["Полезная информация"].to_s.strip.presence
      if g.present?
        attrs[:good_to_know] = g
        attrs[:good_to_know_ru] = g
      end

      s = details["Безопасность и соответствие требованиям"].to_s.strip.presence
      if s.present?
        attrs[:safety_info] = s
        attrs[:safety_info_ru] = s
      end

      materials = normalize_materials(details["Материал и уход"])
      if materials.present?
        attrs[:materials] = materials
        attrs[:materials_ru] = materials
      end

      care = extract_care_instructions(details["Материал и уход"])
      if care.present?
        attrs[:care_instructions] = care
        attrs[:care_instructions_ru] = care
      end

      features = normalize_description(details["Описание"])
      if features.present?
        attrs[:features] = features
        attrs[:features_ru] = features
      end

      manuals, assembly_documents, videos = extract_link_sets
      attrs[:manuals] = manuals if manuals.present?
      attrs[:assembly_documents] = assembly_documents if assembly_documents.present?
      attrs[:videos] = videos if videos.present?
    end

    def assign_media(attrs)
      images = normalize_images(item["images"])
      return if images.blank?

      existing = parse_json_array(product.images)
      merged = (existing + images).compact.uniq
      attrs[:images] = merged if merged.length >= existing.length
    end

    def assign_dimensions_weight_packaging(attrs)
      dimensions_hash, technical_hash = extract_dimensions_and_technical
    
      pack = details["Информация об упаковке"]
      apply_packaging_hash(pack, dimensions_hash, attrs)
    
      extracted_weight = Products::WeightExtractor.extract_kg(
        "size" => dimensions_hash
      )
    
      attrs[:weight] = extracted_weight if extracted_weight.present?
    
      if dimensions_hash.present?
        dim_json = dimensions_hash.to_json
        attrs[:dimensions] = dim_json
        attrs[:dimensions_ru] = dim_json
      end
    
      # Технические поля в JSON для API/админки
      @technical_map = technical_hash
      @dimensions_map = dimensions_hash
    end

    def apply_packaging_hash(pack, dimensions_hash, attrs)
      return unless pack.is_a?(Hash)
    
      p = pack.stringify_keys
    
      width  = p["Ширина"].to_s.strip.presence
      height = p["Высота"].to_s.strip.presence
      length = p["Длина"].to_s.strip.presence
      weight = p["Вес"].to_s.strip.presence
    
      count_raw = p["Упаковка(-и)"] || p["Упаковок"] || p["Количество упаковок"]
      count = count_raw.to_s[/\d+/].to_i
      count = 1 if count <= 0
    
      %w[Ширина Высота Длина].each do |k|
        next if p[k].blank?
    
        dimensions_hash["#{k} упаковки"] ||= p[k].to_s.strip
      end
    
      if width.present? || height.present? || length.present? || weight.present?
        dimensions_hash["packaging"] ||= {}
        dimensions_hash["packaging"]["desc"] ||= "Упаковок: #{count}"
        dimensions_hash["packaging"]["details"] ||= []
    
        detail = {
          "width" => width,
          "height" => height,
          "length" => length,
          "weight" => weight,
          "count" => count,
          "label" => [p["Название"], p["Артикульный номер"]].map(&:presence).compact.join(" · ")
        }.compact
    
        dimensions_hash["packaging"]["details"] << detail
      end
    
      parts = [width, height, length].compact
      attrs[:package_dimensions] = parts.join(" × ") if parts.size >= 2
    end

    def assign_full_attributes_blob(attrs)
      return unless product.respond_to?(:full_attributes=)

      full = {
        "source" => "lt_results_jsonl",
        "sku" => item["sku"],
        "name" => item["name"],
        "small_desc_name" => item["small_desc_name"],
        "categories" => item["categories"],
        "images" => normalize_images(item["images"]),
        "product_url" => item["product_url"],
        "short_description" => item["short_description"],
        "detailed_info" => details,
        "dimensions_map" => @dimensions_map,
        "technical_map" => @technical_map
      }.compact

      attrs[:full_attributes] = full
    end

    def extract_name_from_details
      details["Название"].to_s.strip.presence
    end

    def normalize_item_no(value)
      return nil if value.blank?
      value.to_s.gsub(/[^\d]/, "")
    end

    def extract_designer
      d = details["Дизайнер"].to_s.strip
      return d if d.present?

      desc = details["Описание"]
      if desc.is_a?(Array)
        last = desc.last.to_s.strip
        return last if last.match?(/[A-Za-zА-Яа-я]/)
      end
      nil
    end

    def normalize_description(value)
      case value
      when Array
        value.map(&:to_s).map(&:strip).reject(&:blank?).join("\n").presence
      when String
        value.strip.presence
      end
    end

    def normalize_materials(value)
      case value
      when Hash
        value.map { |k, v| "#{k}: #{v}" }.join("\n").presence
      when String
        value.strip.presence
      end
    end

    def extract_care_instructions(value)
      return nil unless value.is_a?(Hash)

      care_pairs = value.select { |k, _| k.to_s.match?(/уход|care/i) }
      return nil if care_pairs.empty?

      care_pairs.map { |k, v| "#{k}: #{v}" }.join("\n").presence
    end

    def extract_dimensions_and_technical
      dimensions = {}
      technical = {}

      details.each do |key, value|
        key_s = key.to_s
        next if DETAIL_IGNORED_FOR_FLAT.include?(key_s)
        next if value.blank?
        next if value.is_a?(Hash) || value.is_a?(Array)

        if key_s.match?(/длина|ширина|высота|вес|диаметр|глубина|объем|объём/i)
          dimensions[key_s] = value.to_s.strip
        else
          technical[key_s] = value.to_s.strip
        end
      end

      [dimensions, technical]
    end

    def extract_weight_from_dimensions(dimensions_hash)
      Products::WeightExtractor.extract_kg(
        "size" => dimensions_hash
      )
    end

    def parse_weight_scalar(str)
      return nil if str.blank?
      str.to_s.gsub(",", ".").scan(/(\d+(?:\.\d+)?)/).flatten.first&.to_f
    end

    def extract_link_sets
      manuals = normalize_link_array(item["manuals"])
      assembly_documents = normalize_link_array(item["assembly_documents"])
      videos = normalize_link_array(item["videos"])

      assembly_text = details["Сборка и документы"].to_s
      extracted_urls = assembly_text.scan(%r{https?://[^\s<>"']+}).uniq
      if extracted_urls.any? && assembly_documents.blank?
        assembly_documents = extracted_urls.map { |url| { "url" => url } }
      end

      [manuals, assembly_documents, videos]
    end

    def normalize_link_array(values)
      Array(values).filter_map do |value|
        case value
        when Hash
          h = value.stringify_keys
          url = h["url"].to_s.strip
          next if url.blank?
          { "title" => h["title"].presence, "url" => url }.compact
        when String
          url = value.to_s.strip
          next if url.blank?
          { "url" => url }
        end
      end
    end

    def normalize_images(values)
      Array(values).map(&:to_s).map(&:strip).select { |v| v.start_with?("http://", "https://") }
        .reject { |v| v.match?(/pvid/i) }
        .uniq
    end

    def parse_json_array(val)
      return val if val.is_a?(Array)
      return [] if val.blank?
      JSON.parse(val)
    rescue JSON::ParserError
      []
    end
  end
end
