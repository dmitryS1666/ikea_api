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

    module_function

    def suspect?(product)
      payload = ProductSerializer.customer_full_attributes_payload(product)
      texts = deep_strings(payload).uniq
      texts.any? { |text| likely_polish_not_russian?(text) }
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
