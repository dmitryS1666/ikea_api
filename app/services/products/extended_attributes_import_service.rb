module Products
  class ExtendedAttributesImportService
    KEY_MAP = {
      "Paczka(i)" => "кол-во в упаковке",
      "кол-во в упаковке" => "кол-во в упаковке",
      "Opis" => "описание",
      "Описание" => "описание",
      "Szczegóły" => "детали",
      "Детали" => "детали",
      "Tytuł" => "название",
      "Название" => "название",
      "Link" => "ссылка",
      "Ссылка" => "ссылка",
      "Szerokość łóżka" => "ширина кровати",
      "Ширина кровати" => "ширина кровати",
      "Długość łóżka" => "длина кровати",
      "Длина кровати" => "длина кровати",
      "Wysokość z poduchami oparcia" => "высота с подушками спинки",
      "Высота с подушками спинки" => "высота с подушками спинки",
      "Wysokość oparcia" => "высота спинки",
      "Высота спинки" => "высота спинки",
      "Tył" => "задняя часть",
      "сзади" => "задняя часть"
    }.freeze
    def initialize(force_full: false)
      @force_full = force_full
    end

    def process_item(item)
      return :skipped unless item.is_a?(Hash)

      sku = item["sku"].to_s.strip
      return :skipped if sku.blank?

      product = Product.find_by(sku: sku)
      return :skipped unless product

      raw_attributes = item["attributes"] || {}
      mapped_attrs = {}

      assign_if_present(mapped_attrs, "url", item["url"], present_key: item.key?("url"))
      assign_if_present(mapped_attrs, "related_products", item["related_products"], present_key: item.key?("related_products"))

      opis = item["short_description"] || raw_attributes["Opis"]
      if opis.is_a?(Array)
        assign_if_present(mapped_attrs, "short_description", opis.join("\n"), present_key: true)
      elsif opis.is_a?(String)
        assign_if_present(mapped_attrs, "short_description", opis, present_key: true)
      elsif @force_full && (item.key?("short_description") || raw_attributes.key?("Opis"))
        mapped_attrs["short_description"] = nil
      end

      mat_and_care = raw_attributes["Materiały i pielęgnacja"] || {}
      if mat_and_care.is_a?(Hash)
        materials = mat_and_care["Materiały"]
        if materials.is_a?(Hash)
          assign_if_present(mapped_attrs, "materials", materials.map { |k, v| "#{k}: #{v}" }.join("\n"), present_key: true)
        elsif materials.is_a?(String)
          assign_if_present(mapped_attrs, "materials", materials, present_key: true)
        elsif @force_full && mat_and_care.key?("Materiały")
          mapped_attrs["materials"] = nil
        end

        care = mat_and_care["Pielęgnacja"]
        if care.is_a?(Hash)
          assign_if_present(mapped_attrs, "care_instructions", care.map { |k, v|
            vals = v.is_a?(Array) ? v.join(", ") : v
            "#{k}: #{vals}"
          }.join("\n"), present_key: true)
        elsif care.is_a?(Array)
          assign_if_present(mapped_attrs, "care_instructions", care.join("\n"), present_key: true)
        elsif care.is_a?(String)
          assign_if_present(mapped_attrs, "care_instructions", care, present_key: true)
        elsif @force_full && mat_and_care.key?("Pielęgnacja")
          mapped_attrs["care_instructions"] = nil
        end
      end

      assign_if_present(mapped_attrs, "safety_info", raw_attributes["Bezpieczeństwo i zgodność z przepisami"], present_key: raw_attributes.key?("Bezpieczeństwo i zgodność z przepisami"))
      assign_if_present(mapped_attrs, "good_to_know", raw_attributes["Dobrze wiedzieć"], present_key: raw_attributes.key?("Dobrze wiedzieć"))
      assign_if_present(mapped_attrs, "designer", raw_attributes["Projektant"], present_key: raw_attributes.key?("Projektant"))

      if raw_attributes.key?("Montaż i dokumenty")
        mapped_attrs["assembly_documents"] = download_documents(raw_attributes["Montaż i dokumenty"], sku)
      end

      if item.key?("manuals")
        mapped_attrs["manuals"] = download_documents(item["manuals"], sku)
      end

      dimensions_data = {}
      dimension_keys = raw_attributes.keys.select { |k| k =~ /Szerokość|Głębokość|Wysokość|Długość|Waga|Obciążenie|Siedzisko|Łóżko/ }
      dimension_keys.each { |k| dimensions_data[k] = raw_attributes[k] }

      if raw_attributes["Opakowanie"].is_a?(Hash) && raw_attributes["Opakowanie"]["Szczegóły"].is_a?(Array)
        raw_attributes["Opakowanie"]["Szczegóły"].each_with_index do |pkg, idx|
          pkg.each do |pk, pv|
            next if pk == "Paczka(i)"
            dimensions_data["Упаковка #{idx + 1} #{pk}"] = pv
          end
        end
      end

      assign_if_present(mapped_attrs, "dimensions", dimensions_data.to_json, present_key: dimensions_data.present? || @force_full)

      if dimensions_data.present?
        mapped_attrs["dimensions_ru"] = translate_dimensions(dimensions_data)
      elsif @force_full
        mapped_attrs["dimensions_ru"] = nil
      end

      assign_if_present(mapped_attrs, "packaging", raw_attributes["Opakowanie"], present_key: raw_attributes.key?("Opakowanie"))
      assign_if_present(mapped_attrs, "full_attributes", raw_attributes, present_key: item.key?("attributes"))
      if item.key?("attributes")
        mapped_attrs["full_attributes_ru"] = build_full_attributes_ru(
          raw_attributes,
          short_description: mapped_attrs["short_description"],
          care_instructions: mapped_attrs["care_instructions"],
          materials: mat_and_care["Materiały"],
          assembly_documents: mapped_attrs["assembly_documents"],
          manuals: mapped_attrs["manuals"]
        )
      elsif @force_full
        mapped_attrs["full_attributes_ru"] = {}
      end

      weight_fields = extract_weight_fields(raw_attributes, item)
      mapped_attrs.merge!(weight_fields) if weight_fields.present?

      translated_attrs = {}
      mapped_attrs.each do |key, value|
        next if %w[assembly_documents dimensions dimensions_ru packaging full_attributes care_instructions manuals].include?(key)
        next if value.blank?

        if value.is_a?(String)
          begin
            translated_attrs["#{key}_ru"] = translate_text_ru(value)
          rescue => e
            Rails.logger.error("[Import] Translation error for #{sku} field #{key}: #{e.message}")
          end
        end
      end

      if mapped_attrs.key?("care_instructions")
        if mapped_attrs["care_instructions"].present?
          begin
            translated_attrs["care_instructions_ru"] = translate_text_ru(mapped_attrs["care_instructions"])
          rescue => e
            Rails.logger.error("[Import] Translation error for #{sku} field care_instructions: #{e.message}")
            translated_attrs["care_instructions_ru"] = mapped_attrs["care_instructions"]
          end
        elsif @force_full
          translated_attrs["care_instructions_ru"] = nil
        end
      end

      final_attrs = mapped_attrs.merge(translated_attrs)

      product.update_columns(final_attrs.slice(
        "url",
        "short_description",
        "short_description_ru",
        "materials",
        "materials_ru",
        "care_instructions",
        "care_instructions_ru",
        "safety_info",
        "safety_info_ru",
        "good_to_know",
        "good_to_know_ru",
        "designer",
        "designer_ru",
        "assembly_documents",
        "manuals",
        "packaging",
        "weight",
        "net_weight",
        "package_volume",
        "package_dimensions",
        "related_products",
        "full_attributes",
        "full_attributes_ru",
        "dimensions",
        "dimensions_ru"
      ))

      :updated
    rescue => e
      Rails.logger.error("[Import] sku=#{item['sku']} error=#{e.class}: #{e.message}")
      :error
    end

    private

    def assign_if_present(hash, key, value, present_key:)
      return if !@force_full && value.blank?
      return if @force_full == false && value.blank?
      return if !present_key && !@force_full

      hash[key] = value
    end

    def download_documents(documents, sku)
      Array(documents).filter_map do |doc|
        if doc.is_a?(Hash)
          title = doc["title"] || doc["Tytuł"] || doc["Tytul"] || doc["name"] || doc[:title] || doc[:name]
          url = doc["url"] || doc["Link"] || doc["href"] || doc[:url]
        else
          title = nil
          url = doc.to_s
        end

        next if url.blank?

        local_url = DocumentDownloader.download(url, product_sku: sku)
        { "title" => title, "url" => url, "local_url" => local_url }.compact
      end
    end

    def build_full_attributes_ru(raw_attributes, short_description:, care_instructions:, materials:, assembly_documents:, manuals:)
      {
        "description" => build_description_section(raw_attributes, short_description),
        "size" => build_dimensions_section(raw_attributes),
        "materials" => build_materials_section(materials, care_instructions),
        "instructions" => build_instructions_section(assembly_documents, manuals)
      }.compact
    end

    def transform_keys_ru(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[translate_key_ru(k)] = transform_keys_ru(v)
        end
      when Array
        value.map { |item| transform_keys_ru(item) }
      else
        translate_value_ru(value)
      end
    end

    def translate_key_ru(key)
      KEY_MAP[key.to_s] || translate_key_to_russian(key.to_s)
    end

    def translate_key_to_russian(key)
      translate_text_ru(key, source_lang: detect_lang(key))
    end

    def detect_lang(text)
      return 'ru' if text =~ /[А-Яа-яЁё]/
      'pl'
    end

    def build_description_section(raw_attributes, short_description)
      section = {}

      if short_description.present?
        section["short_description"] = translate_value_ru(short_description)
      end

      opis = raw_attributes["Opis"]
      if opis.present?
        section["description"] = translate_value_ru(opis)
      end

      section.presence
    end

    def build_dimensions_section(raw_attributes)
      section = {}

      width = raw_attributes["Szerokość"] || raw_attributes["width"]
      depth = raw_attributes["Głębokość"] || raw_attributes["depth"]
      section["width"] = width if width.present?
      section["depth"] = depth if depth.present?

      packaging = raw_attributes["Opakowanie"]
      if packaging.is_a?(Hash)
        section["packaging"] = build_packaging_section(packaging)
      end

      other_keys = raw_attributes.keys.select do |k|
        k =~ /Szerokość|Głębokość|Wysokość|Długość|Waga|Obciążenie|Siedzisko|Łóżko|Glebokosc|Wysokosc|Dlugosc/ &&
          !["Szerokość", "Głębokość", "Width", "Depth"].include?(k)
      end
      other_keys.each do |key|
        section[translate_key_ru(key)] = raw_attributes[key]
      end

      section.presence
    end

    def build_materials_section(materials, care_instructions)
      return nil if materials.blank? && care_instructions.blank?

      section = {}
      section["desc"] = translate_value_ru(care_instructions) if care_instructions.present?
      if materials.is_a?(Hash)
        section["materials"] = transform_keys_ru(materials)
      elsif materials.present?
        section["materials"] = translate_value_ru(materials)
      end
      section.presence
    end

    def build_instructions_section(assembly_documents, manuals)
      documents = Array(assembly_documents) + Array(manuals)
      return nil if documents.blank?

      files = documents.filter_map do |doc|
        next unless doc.is_a?(Hash)
        url = doc["local_url"].presence || doc["url"]
        next if url.blank?
        {
          "title" => translate_value_ru(doc["title"]),
          "link" => url
        }.compact
      end

      files.present? ? { "files" => files } : nil
    end

    def translate_value_ru(value)
      return value if value.is_a?(Numeric)
      return value if value == true || value == false

      if value.is_a?(Array)
        return value.map { |v| translate_value_ru(v) }
      end

      if value.is_a?(Hash)
        return value.each_with_object({}) { |(k, v), acc| acc[translate_key_ru(k)] = translate_value_ru(v) }
      end

      text = value.to_s
      return text if keep_units?(text)

      translate_text_ru(text)
    end

    def translate_values_only(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[k] = translate_value_ru(v)
        end
      when Array
        value.map { |v| translate_value_ru(v) }
      else
        translate_value_ru(value)
      end
    end

    def translate_text_ru(text, source_lang: 'pl')
      original = text.to_s
      translated = TranslationService.translate(original, target_lang: 'ru', source_lang: source_lang, force: true, skip_mymemory: true, skip_google: true)
      if TranslationService.invalid_translation?(translated, original)
        translated = TranslationService.translate(original, target_lang: 'ru', source_lang: source_lang, force: true, skip_mymemory: false, skip_google: true)
      end
      TranslationService.invalid_translation?(translated, original) ? original : translated
    end

    def build_packaging_section(packaging)
      section = {}
      section["desc"] = translate_value_ru(packaging["Opis"] || packaging["Описание"] || packaging["Desc"]) if packaging.is_a?(Hash)

      details = packaging["Szczegóły"] || packaging["Детали"] || packaging["details"]
      if details.is_a?(Array)
        section["details"] = details.map do |detail|
          next unless detail.is_a?(Hash)
          {
            "weight" => detail["Waga"] || detail["Вес"],
            "length" => detail["Długość"] || detail["Длина"],
            "height" => detail["Wysokość"] || detail["Высота"],
            "width" => detail["Szerokość"] || detail["Ширина"],
            "count" => detail["Paczka(i)"] || detail["кол-во в упаковке"]
          }.compact
        end.compact
      end

      section.presence
    end

    def keep_units?(text)
      return false if text.blank?
      return true if text.match?(/\A[\d\s.,xх×\-\+%]*(cm|mm|kg|g|l|м|м2|m2|m3|%)?[\d\s.,xх×\-\+%]*\z/i)
      false
    end

    def extract_weight_fields(raw_attributes, item)
      result = {}

      weight = extract_number_from_key(raw_attributes, ["Waga", "Вес"]) || extract_number(item["weight"])
      weight ||= extract_packaging_weight(raw_attributes)
      net_weight = extract_number_from_key(raw_attributes, ["Waga netto", "Вес нетто"]) || extract_number(item["net_weight"])
      package_volume = extract_number_from_key(raw_attributes, ["Objętość opakowania", "Объем упаковки", "Pojemność opakowania"]) || extract_number(item["package_volume"])
      package_dimensions = extract_package_dimensions(raw_attributes) || item["package_dimensions"]

      result["weight"] = weight if weight
      result["net_weight"] = net_weight if net_weight
      result["package_volume"] = package_volume if package_volume
      result["package_dimensions"] = package_dimensions if package_dimensions.present?

      result
    end

    def extract_packaging_weight(raw_attributes)
      packaging = raw_attributes["Opakowanie"]
      return nil unless packaging.is_a?(Hash)

      details = packaging["Szczegóły"] || packaging["Детали"]
      return nil unless details.is_a?(Array)

      total = details.filter_map { |detail| extract_number(detail["Waga"] || detail["Вес"]) }.sum
      total.positive? ? total : nil
    end

    def extract_number_from_key(raw_attributes, keys)
      keys.each do |key|
        value = raw_attributes[key]
        number = extract_number(value)
        return number if number
      end
      nil
    end

    def extract_package_dimensions(raw_attributes)
      return raw_attributes["Wymiary opakowania"] if raw_attributes["Wymiary opakowania"].present?
      return raw_attributes["Package dimensions"] if raw_attributes["Package dimensions"].present?

      packaging = raw_attributes["Opakowanie"]
      return nil unless packaging.is_a?(Hash)

      details = packaging["Szczegóły"]
      return nil unless details.is_a?(Array) && details.any?

      first = details.first
      return nil unless first.is_a?(Hash)

      width = extract_number(first["Szerokość"] || first["width"])
      height = extract_number(first["Wysokość"] || first["height"])
      length = extract_number(first["Długość"] || first["length"])

      return nil if [width, height, length].all?(&:nil?)

      [length, width, height].compact.join("x") + " cm"
    end

    def extract_number(value)
      return nil if value.blank?

      str = value.to_s.tr(",", ".")
      match = str.match(/(\d+(\.\d+)?)/)
      match ? match[1].to_f : nil
    end

    def translate_dimensions(dimensions_data)
      translated_dimensions = {}
      dimensions_data.each do |k, v|
        if k =~ /^(Упаковка \d+)\s+(.+)$/
          prefix = $1
          polish_part = $2.strip
          translated_part = translate_short(polish_part)
          translated_key = "#{prefix} #{translated_part}"
        else
          translated_key = TranslationService.translate(k)
        end
        translated_dimensions[translated_key] = v
      end
      translated_dimensions.to_json
    end

    def translate_short(text)
      TranslationService.translate(text, force: true, skip_mymemory: true)
    end
  end
end
