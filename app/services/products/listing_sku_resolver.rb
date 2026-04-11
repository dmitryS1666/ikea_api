# frozen_string_literal: true

module Products
  # SKU с витрины PL часто приходит как s12345678, в БД после JSON-импорта — 12345678.
  # При актуализации категории всегда ищем существующую строку по любому из вариантов записи.
  module ListingSkuResolver
    module_function

    def aliases(raw)
      s = raw.to_s.strip
      return [] if s.blank?

      core = s.sub(/\As/i, "")
      [s, core, "s#{core}"].uniq
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
