# frozen_string_literal: true

module Products
  # Нормализация артикула IKEA (8 цифр, ведущие нули, опциональный префикс s).
  module ArticleNumber
    module_function

    def normalize(raw)
      return nil if raw.blank?

      if raw.is_a?(Hash)
        nested = raw["item"] || raw[:item]
        tokens = [
          raw["sku"], raw[:sku],
          raw["item_no"], raw[:item_no],
          raw["itemNo"], raw[:itemNo],
          raw["itemNoGlobal"], raw[:itemNoGlobal],
          raw["articleNumber"], raw[:articleNumber],
          raw["id"], raw[:id],
          raw["value"], raw[:value],
          nested
        ].compact
        return tokens.lazy.filter_map { |t| normalize(t) }.first
      end

      s = raw.to_s.gsub(/[\[\]\"]/, "").strip
      return nil if s.blank?

      compact = s.gsub(/[^0-9a-z]/i, "").downcase
      return nil if compact.blank?

      digits =
        if compact.match?(/\As\d+\z/)
          compact.delete_prefix("s")
        elsif compact.match?(/\A\d+\z/)
          compact
        else
          m = s.match(/(\d{8})/)
          m&.[](1)
        end

      return nil if digits.blank?
      return nil unless digits.match?(/\A\d+\z/)

      digits = digits[-8, 8] if digits.length > 8
      digits.rjust(8, "0")
    end

    def normalize_list(values)
      Array(values).flat_map { |v| normalize(v) }.compact.uniq
    end
  end
end
