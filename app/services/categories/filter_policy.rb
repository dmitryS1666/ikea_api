# frozen_string_literal: true

module Categories
  # Политика источников фильтров каталога.
  #
  # Характеристики товара (цвет, материал, форма, серия и т. п.) приходят из
  # фасетного API IKEA. Локальный индексатор не должен пытаться восстановить их
  # по тексту карточки, иначе он перезапишет точные связи IKEA эвристиками.
  module FilterPolicy
    REQUIRED_PARAMETERS = {
      "f-price-buckets" => "Цена"
    }.freeze

    OPTIONAL_PARAMETERS = {
      "f-series" => "Коллекция",
      "f-material" => "Материал",
      "f-materials" => "Материал",
      "f-colors" => "Цвет",
      "f-feature" => "Свойства",
      "f-size" => "Размер",
      "f-measurement-buckets" => "Размер",
      "f-shape" => "Форма",
      "f-type" => "Тип",
      "f-firmness" => "Жесткость",
      "f-number-of-seats" => "Количество мест",
      "f-ratings" => "Рейтинг",
      "f-special-price" => "Акции"
    }.freeze

    ALLOWED_PARAMETERS = REQUIRED_PARAMETERS.merge(OPTIONAL_PARAMETERS).freeze
    PARAMETER_ORDER = (REQUIRED_PARAMETERS.keys + OPTIONAL_PARAMETERS.keys).freeze

    # Только эти параметры допустимо рассчитывать из локальных данных.
    LOCAL_PARAMETERS = %w[
      f-price-buckets
      f-ratings
      f-special-price
    ].freeze

    # Служебные фасеты IKEA не показываются как фильтры каталога.
    HIDDEN_PARAMETERS = %w[f-availability f-subcategories].freeze
    GLOBAL_EXCLUDED_PARAMETERS = HIDDEN_PARAMETERS

    module_function

    def display_name(parameter)
      ALLOWED_PARAMETERS[parameter.to_s]
    end

    def required?(parameter)
      REQUIRED_PARAMETERS.key?(parameter.to_s)
    end

    def allowed?(parameter, category: nil)
      parameter = parameter.to_s
      parameter.start_with?("f-") && !excluded?(parameter, category: category)
    end

    def excluded?(parameter, category: nil)
      HIDDEN_PARAMETERS.include?(parameter.to_s)
    end

    def local?(parameter)
      LOCAL_PARAMETERS.include?(parameter.to_s)
    end

    def upstream?(parameter)
      parameter = parameter.to_s
      allowed?(parameter) && !local?(parameter)
    end

    def order_index(parameter)
      index = PARAMETER_ORDER.index(parameter.to_s)
      index || PARAMETER_ORDER.length
    end

    def normalize_text(value)
      text = value.to_s.downcase
      replacements = {
        "ą" => "a", "č" => "c", "ć" => "c", "ę" => "e", "ė" => "e", "į" => "i",
        "š" => "s", "ų" => "u", "ū" => "u", "ž" => "z", "ł" => "l", "ń" => "n",
        "ó" => "o", "ś" => "s", "ź" => "z", "ż" => "z", "ä" => "a", "ö" => "o",
        "ü" => "u", "å" => "a", "ё" => "е"
      }
      replacements.each { |from, to| text = text.tr(from, to) }
      text.tr("\u00A0", " ").squeeze(" ").strip
    end
  end
end
