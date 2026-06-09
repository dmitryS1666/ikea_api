# frozen_string_literal: true

module Categories
  # Единая политика видимости фильтров каталога.
  # Используется и при обновлении Category#available_filters, и при переиндексации ProductFilterValue.
  module FilterPolicy
    REQUIRED_PARAMETERS = {
      "f-series" => "Коллекция",
      "f-price-buckets" => "Цена",
      "f-material" => "Материал",
      "f-colors" => "Цвет"
    }.freeze

    OPTIONAL_PARAMETERS = {
      "f-feature" => "Свойства",
      "f-size" => "Размер",
      "f-shape" => "Форма",
      "f-type" => "Тип"
    }.freeze

    ALLOWED_PARAMETERS = REQUIRED_PARAMETERS.merge(OPTIONAL_PARAMETERS).freeze
    PARAMETER_ORDER = (REQUIRED_PARAMETERS.keys + OPTIONAL_PARAMETERS.keys).freeze

    GLOBAL_EXCLUDED_PARAMETERS = %w[
      f-firmness
      f-number-of-seats
    ].freeze

    LIGHTING_EXCLUDED_PARAMETERS = %w[f-shape].freeze

    LIGHTING_KEYWORDS = %w[
      освещ свет ламп lighting light lamp apšviet apsviet oświetl oswiet
    ].freeze

    module_function

    def display_name(parameter)
      ALLOWED_PARAMETERS[parameter.to_s]
    end

    def required?(parameter)
      REQUIRED_PARAMETERS.key?(parameter.to_s)
    end

    def allowed?(parameter, category: nil)
      parameter = parameter.to_s
      ALLOWED_PARAMETERS.key?(parameter) && !excluded?(parameter, category: category)
    end

    def excluded?(parameter, category: nil)
      parameter = parameter.to_s
      return true if GLOBAL_EXCLUDED_PARAMETERS.include?(parameter)
      return true if LIGHTING_EXCLUDED_PARAMETERS.include?(parameter) && lighting_category?(category)

      false
    end

    def order_index(parameter)
      PARAMETER_ORDER.index(parameter.to_s) || PARAMETER_ORDER.length
    end

    def lighting_category?(category)
      return false unless category

      memo_key = :@_categories_filter_policy_lighting
      return category.instance_variable_get(memo_key) if category.instance_variable_defined?(memo_key)

      text = category_text_with_ancestors(category)
      result = LIGHTING_KEYWORDS.any? { |keyword| text.include?(keyword) }
      category.instance_variable_set(memo_key, result)
      result
    end

    def category_text_with_ancestors(category)
      current = [category.name, category.translated_name, category.cached_slug, safe_slug(category)]

      ancestor_ids = Category.normalize_parent_ids(category.parent_ids)
      ancestor_texts =
        if ancestor_ids.present?
          Category.where(ikea_id: ancestor_ids).pluck(:name, :translated_name, :cached_slug).flatten
        else
          []
        end

      normalize_text((current + ancestor_texts).compact.join(" "))
    end

    def safe_slug(category)
      category.slug
    rescue StandardError
      nil
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
