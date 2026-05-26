# frozen_string_literal: true

module Products
  # SKU с витрины PL часто приходит как s12345678, в БД после JSON-импорта — 12345678.
  # При актуализации категории всегда ищем существующую строку по любому из вариантов записи.
  module ListingSkuResolver
    module_function

    # Витрина иногда отдаёт `id` как массив артикулов; `Array#to_s` даёт строку вида
    # '["s123","s456"]' — её нельзя сохранять в products.sku.
    def coerce_listing_identifier(raw)
      case raw
      when nil, false, ""
        nil
      when Array
        raw.lazy.filter_map { coerce_listing_identifier(_1) }.first
      when Hash
        coerce_listing_identifier(
          raw["id"] || raw[:id] || raw["sku"] || raw[:sku] ||
            raw["itemNo"] || raw[:itemNo] || raw["itemNoGlobal"] || raw[:itemNoGlobal]
        )
      when String
        s = raw.strip
        return nil if s.blank?
        if s.start_with?("[")
          begin
            parsed = JSON.parse(s)
            return coerce_listing_identifier(parsed)
          rescue JSON::ParserError
            return nil
          end
        end
        s.presence
      when Numeric
        raw.to_s.strip.presence
      else
        coerce_listing_identifier(raw.to_s)
      end
    end

    # Возвращает набор SKU-кандидатов для поиска Product.
    #
    # Внутренние API-вызовы обычно передают `79578593` или `s79578593`,
    # а публичная карточка/Next route может передать весь slug: `saltsjobaden-79578593`
    # или ошибочный старый вариант `saltsjobaden-s79578593`. Поэтому дополнительно
    # достаём последний 8-значный артикул из публичного идентификатора.
    def aliases(raw)
      coerced = coerce_listing_identifier(raw)
      s = coerced.to_s.strip
      return [] if s.blank?

      candidates = [s]

      public_core = article_core_from_public_identifier(s)
      candidates << public_core if public_core.present?

      candidates.flat_map do |candidate|
        core = candidate.to_s.strip.sub(/\As/i, "")
        [candidate.to_s.strip, core, "s#{core}"]
      end.reject(&:blank?).uniq
    end

    def article_core_from_public_identifier(raw)
      token = raw.to_s.strip.split(/[?#]/, 2).first.to_s.split("/").reject(&:blank?).last.to_s
      return nil if token.blank?

      # Поддерживаем оба публичных варианта:
      #   saltsjobaden-79578593
      #   saltsjobaden-s79578593
      match = token.match(/(?:^|[-_])s?(\d{8})\z/i)
      match && match[1]
    end

    def find_product(raw)
      aliases(raw).each do |candidate|
        p = Product.find_by(sku: candidate)
        return p if p
      end
      nil
    end
  end
end
