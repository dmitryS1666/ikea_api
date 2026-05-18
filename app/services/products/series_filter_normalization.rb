# frozen_string_literal: true

module Products
  # Единая нормализация подписей фильтра f-series (IKEA отдаёт «Серия X», «Серия для … X», «X»).
  # По нормализованному ключу можно схлопывать дубликаты в available_filters и в API.
  module SeriesFilterNormalization
    module_function

    # Подпись для available_filters / API без префиксов «Серия …», «Серия для …».
    def display_name(name_or_id)
      return nil if name_or_id.blank?

      strip_series_prefixes(name_or_id.to_s.dup).presence
    end

    def normalize_key(name_or_id)
      return nil if name_or_id.blank?

      text = normalize_series_token(strip_series_prefixes(name_or_id.to_s.dup))
      text.presence
    end

    # Одна строка фильтра на логическую серию: короткое имя и стабильный id.
    def pick_canonical_value_row(rows)
      rows = Array(rows).filter_map { |v| v.is_a?(Hash) ? v.deep_stringify_keys : nil }
      return nil if rows.empty?
      return rows.first if rows.one?

      rows.min_by do |r|
        name = r["name"].to_s
        [name.length, r["id"].to_s]
      end
    end

    def normalize_series_token(value)
      normalize_text(value).upcase
    end

    def normalize_text(value)
      return "" if value.blank?

      text = value.to_s.downcase
      text = text.tr("ąćęłńóśźżäöüå", "acelnoszzaoua")
      text = text.tr("ё", "е")
      text.tr("\u00A0", " ").squeeze(" ").strip
    end

    def strip_series_prefixes(text)
      text = text.tr("ё", "е")
      text = text.gsub(/\A\s*[СC]\s*ЕРИЯ\s+ДЛЯ\s+.*?\s+/i, "")
      text = text.gsub(/\A\s*[СC]\s*ЕРИЯ\s+/i, "")
      text = text.gsub(/\A\s*СЕРИЯ\s+ДЛЯ\s+.*?\s+/i, "")
      text = text.gsub(/\A\s*СЕРИЯ\s+/i, "")
      text = text.gsub(/\A\s*СТЕЛЛАЖИ\s+/i, "")
      text = text.gsub(/\A\s*КНИЖНЫЕ ШКАФЫ\s+/i, "")
      text = text.gsub(/\A\s*ДВЕРИ\s+/i, "")
      text = text.gsub(/\A\s*ФУРНИТУРА И ВНУТРЕННИЕ ОРГАНАЙЗЕРЫ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ СТУЛЬЯ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ СТОЛЫ\s+/i, "")
      text = text.gsub(/\A\s*ОБЕДЕННЫЕ ГАРНИТУРЫ\s+/i, "")
      text = text.gsub(/\A\s*АКСЕССУАРЫ\s+/i, "")
      text = text.gsub(/\A\s*ПЕРФОРИРОВАННЫЕ ДОСКИ\s+/i, "")
      text = text.gsub(/\A\s*ВСТАВКИ И АКСЕССУАРЫ ДЛЯ\s+/i, "")
      text.squeeze(" ").strip
    end
    private_class_method :strip_series_prefixes
  end
end
