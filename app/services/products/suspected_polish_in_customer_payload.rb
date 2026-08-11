# frozen_string_literal: true

module Products
  # Та же эвристика, что в CountBrokenProductTranslationsJob: подозрительный польский
  # в том payload, что отдаёт API (`ProductSerializer.customer_full_attributes_payload`).
  module SuspectedPolishInCustomerPayload
    PL_MARKERS = %w[
      materiał materiały wymiary waga szerokość wysokość głębokość opakowanie
      sztuk zestaw elementów instrukcja montażu pranie prać
      pokrycie obicia nóżki podłokietnik zawiera skład
    ].freeze

    # Поля, которые реально чинит RecoverBrokenProductTranslationsJob (LT/AI описаний).
    DESCRIPTIVE_PATH_RE =
      /(?:^|\.)(?:content|materials|features|care(?:_instructions)?|description|detailed_info|product_details(?:_modal)?|small_desc_name|short_desc_name|short_description|safety(?:_info)?|good_to_know)(?:\.|$|\[)/i.freeze

    module_function

    def suspect?(product)
      polish_hits(product).any?
    end

    # Польский в описаниях/материалах/уходе — то, что recovery умеет исправить.
    def descriptive_suspect?(product)
      polish_hits(product).any? { |hit| descriptive_path?(hit[:path]) }
    end

    def polish_hits(product)
      payload = ProductSerializer.customer_full_attributes_payload(product)
      hits = []
      walk_strings(payload, "root") do |path, text|
        hits << { path: path, text: text } if likely_polish_not_russian?(text)
      end
      hits
    end

    def descriptive_path?(path)
      path.to_s.match?(DESCRIPTIVE_PATH_RE)
    end

    def deep_strings(obj, acc = [])
      case obj
      when String
        stripped = obj.strip
        acc << stripped if stripped.length >= 12
      when Hash
        obj.each_value { |v| deep_strings(v, acc) }
      when Array
        obj.each { |v| deep_strings(v, acc) }
      end
      acc
    end

    def walk_strings(obj, path, &block)
      case obj
      when String
        stripped = obj.strip
        yield(path, stripped) if stripped.length >= 12
      when Hash
        obj.each { |k, v| walk_strings(v, "#{path}.#{k}", &block) }
      when Array
        obj.each_with_index { |v, i| walk_strings(v, "#{path}[#{i}]", &block) }
      end
    end

    def likely_polish_not_russian?(text)
      return false if text.blank? || text.length < 12

      cyr = text.scan(/[а-яА-ЯёЁ]/).size
      lat = text.scan(/[A-Za-zÀ-ÿ]/).size
      return false if lat < 8
      return false if cyr >= 12 || (lat.positive? && (cyr.to_f / (cyr + lat)) > 0.25)
      return true if text.match?(/[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]/)

      low = text.downcase
      PL_MARKERS.any? { |word| low.include?(word) }
    end
  end
end
