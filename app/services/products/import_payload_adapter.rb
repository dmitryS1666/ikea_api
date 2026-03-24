module Products
  class ImportPayloadAdapter
    STRUCTURED_KEYS = %w[identity pricing content media attributes connections].freeze
    RESULTS_JSONL_KEYS = %w[sku price category_id categories images product_url short_description variants related_products].freeze
    RESERVED_DETAIL_KEYS = [
      'Полное описание',
      'Описание',
      'Полезная информация',
      'Материал и уход',
      'Безопасность и соответствие требованиям',
      'Сборка и документы',
      'Артикульный номер',
      'Информация об упаковке',
      'Дизайнер',
      'Проект'
    ].freeze

    DIMENSION_KEY_PATTERN = /(ширин|высот|глубин|длин|диаметр|толщин|вес|объем|объ[её]м|площад|нагруз|количеств|каркас|сидень|спальн|матрас|основани|провод|внутрен|светов|температур|срок службы|длина кровати|ширина кровати|высота сиденья|глубина сиденья)/i.freeze

    def self.normalize(item, format: nil)
      new(item, format: format).normalize
    end

    def initialize(item, format: nil)
      @item = item || {}
      @format = format.to_s.presence
    end

    def normalize
      return @item unless @item.is_a?(Hash)
      return @item if structured_payload?
      return adapt_results_jsonl if results_jsonl_payload?

      @item
    end

    private

    def structured_payload?
      STRUCTURED_KEYS.any? { |key| @item.key?(key) }
    end

    def results_jsonl_payload?
      return true if @format == 'results_jsonl'

      RESULTS_JSONL_KEYS.count { |key| @item.key?(key) } >= 5 && @item.key?('Подробная информация о товаре')
    end

    def adapt_results_jsonl
      details = (@item['Подробная информация о товаре'] || {}).to_h
      material_and_care = details['Материал и уход']
      materials_payload = extract_materials(material_and_care)
      care_payload = extract_care(material_and_care)
      dimensions_payload, technical_payload = extract_dimensions_and_technical(details)
      full_description = extract_full_description(@item, details)
      features_payload = normalize_feature_list(details['Описание'])
      category_id = @item['category_id'].to_s.presence

      {
        '_import_meta' => {
          'source_format' => 'results_jsonl',
          'trusted_images' => true
        },
        'sku' => @item['sku'].to_s.strip,
        'identity' => {
          'name' => infer_name(@item, details),
          'name_ru' => infer_name(@item, details),
          'article_number' => normalize_article_number(details['Артикульный номер']) || @item['sku'].to_s.strip,
          'product_url' => @item['product_url'] || @item['url'],
          'category_id' => category_id
        },
        'pricing' => {
          'price' => normalize_price(@item['price'])
        },
        'content' => {
          'short_description' => normalized_text(@item['short_description']),
          'full_description' => full_description,
          'designer' => normalized_text(details['Дизайнер'] || details['Проект']),
          'categories' => normalize_categories(@item['categories'], category_id),
          'features' => features_payload
        },
        'media' => {
          'images' => normalize_images(@item['images'])
        },
        'attributes' => {
          'dimensions' => dimensions_payload.presence,
          'technical' => technical_payload.presence,
          'materials' => materials_payload.presence,
          'care_instructions' => care_payload.presence,
          'additional_info' => {
            'good_to_know' => normalized_text(details['Полезная информация']),
            'safety_info' => normalized_text(details['Безопасность и соответствие требованиям']),
            'packaging' => details['Информация об упаковке'],
            'assembly_documents' => normalize_documents(details['Сборка и документы'])
          }.compact,
          'features' => features_payload.presence,
          'manuals' => normalize_documents(details['Сборка и документы']),
          'packaging' => details['Информация об упаковке']
        },
        'connections' => {
          'related_products' => normalize_sku_list(@item['related_products']),
          'variants' => normalize_variants(@item['variants'])
        },
        'raw_data_dump' => {
          'source' => 'results_jsonl',
          'source_payload' => @item,
          'details' => details
        }
      }
    end

    def infer_name(item, details)
      explicit = item['name'] || item.dig('identity', 'name') || details['Название'] || details['Наименование']
      return explicit.to_s.strip if explicit.present?

      slug_source = (item['product_url'] || item['url']).to_s
      slug = slug_source.split('/').reject(&:blank?).last.to_s
      slug = slug.sub(/-\d{8}$/, '')
      fallback = slug.tr('-', ' ').squeeze(' ').strip
      return fallback.titleize if fallback.present?

      "SKU #{item['sku']}"
    end

    def normalize_price(value)
      return nil if value.blank?
      return value if value.is_a?(Numeric)

      normalized = value.to_s.gsub(/[^\d,\.]/, '').tr(',', '.')
      return nil if normalized.blank?

      normalized.to_f
    end

    def normalize_article_number(value)
      return nil if value.blank?
      value.to_s.gsub(/[^\d]/, '')
    end

    def normalize_categories(raw_categories, primary_category_id)
      categories = Array(raw_categories).filter_map do |entry|
        case entry
        when Hash
          id = entry['id'] || entry[:id]
          next if id.blank?
          next unless id.to_s == primary_category_id.to_s || id.to_s.match?(/^\d+$/)

          {
            'id' => id.to_s,
            'name' => (entry['name'] || entry[:name]).to_s.presence,
            'url' => (entry['url'] || entry[:url]).to_s.presence
          }.compact
        else
          id = entry.to_s
          next if id.blank?
          next unless id == primary_category_id.to_s || id.match?(/^\d+$/)
          { 'id' => id }
        end
      end

      if primary_category_id.present? && categories.none? { |c| c['id'].to_s == primary_category_id.to_s }
        categories << { 'id' => primary_category_id.to_s }
      end

      categories.uniq { |c| c['id'].to_s }
    end

    def normalize_images(raw_images)
      Array(raw_images).filter_map do |image|
        url = image.is_a?(Hash) ? (image['url'] || image[:url] || image['src'] || image[:src]) : image
        url = url.to_s.strip
        next if url.blank?
        next unless url.start_with?('http://', 'https://')
        url
      end.uniq
    end

    def normalize_sku_list(raw_values)
      Array(raw_values).filter_map do |value|
        case value
        when Hash
          sku = value['sku'] || value[:sku] || value['id'] || value[:id]
          sku.to_s.gsub(/\D/, '').presence || value['url'] || value[:url]
        else
          str = value.to_s.strip
          next if str.blank?
          digits = str.gsub(/\D/, '')
          digits.presence || str
        end
      end.uniq
    end

    def normalize_variants(raw_variants)
      Array(raw_variants).filter_map do |value|
        case value
        when Hash
          value.deep_stringify_keys
        else
          sku = value.to_s.gsub(/\D/, '')
          next if sku.blank?
          { 'sku' => sku }
        end
      end
    end

    def normalize_documents(raw_documents)
      case raw_documents
      when Array
        raw_documents.filter_map do |entry|
          if entry.is_a?(Hash)
            url = entry['url'] || entry[:url] || entry['Link'] || entry[:Link]
            title = entry['title'] || entry[:title] || entry['Tytuł'] || entry[:Tytuł]
            next if url.blank?
            { 'title' => title, 'url' => url }.compact
          else
            url = entry.to_s.strip
            next if url.blank? || !url.start_with?('http://', 'https://')
            { 'url' => url }
          end
        end
      else
        []
      end
    end

    def extract_materials(value)
      return nil if value.blank?

      if value.is_a?(Hash)
        material_value = value['Материалы'] || value['Материал'] || value['Materials']
        return material_value if material_value.present?

        care_keys = value.keys.select { |k| k.to_s.match?(/уход|care/i) }
        material_hash = value.except(*care_keys)
        return material_hash if material_hash.present?
      end

      value
    end

    def extract_care(value)
      return nil if value.blank?

      if value.is_a?(Hash)
        return value['Уход'] || value['Порядок ухода'] || value['Care'] if value['Уход'].present? || value['Порядок ухода'].present? || value['Care'].present?

        care_pairs = value.select { |k, _| k.to_s.match?(/уход|care/i) }
        return care_pairs if care_pairs.present?
        return nil
      end

      nil
    end

    def extract_dimensions_and_technical(details)
      dimensions = {}
      technical = {}

      details.each do |key, value|
        next if RESERVED_DETAIL_KEYS.include?(key)
        next if value.blank?
        next if value.is_a?(Array) || value.is_a?(Hash)

        normalized = normalized_text(value)
        next if normalized.blank?

        if key.to_s.match?(DIMENSION_KEY_PATTERN)
          dimensions[key] = normalized
        else
          technical[key] = normalized
        end
      end

      [dimensions, technical]
    end

    def extract_full_description(item, details)
      full = details['Полное описание']
      full = item['full_description'] if full.blank?
      normalized_text(full).presence || normalized_text(details['Описание'])
    end

    def normalize_feature_list(value)
      case value
      when Array
        value.map { |entry| normalized_text(entry) }.compact_blank
      when String
        split_lines(value)
      else
        []
      end
    end

    def split_lines(value)
      value.to_s.split(/\r?\n|•|\u2022|\./).map { |part| part.to_s.strip }.reject(&:blank?)
    end

    def normalized_text(value)
      case value
      when Array
        value.map { |entry| entry.to_s.strip }.reject(&:blank?).join("\n")
      when Hash
        value.transform_values { |entry| entry.is_a?(String) ? entry.strip : entry }
      else
        str = value.to_s.strip
        str.presence
      end
    end
  end
end
