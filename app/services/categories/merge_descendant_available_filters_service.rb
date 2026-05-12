# frozen_string_literal: true

module Categories
  # Собирает уникальные значения фильтров (в т.ч. f-series) из available_filters
  # всех потомков и объединяет их с фильтрами текущей категории.
  #
  # Используется для родительских категорий: в API список значений берётся из
  # category.available_filters, а счётчики уже агрегируются по дереву (Category#display_filters_for_api).
  class MergeDescendantAvailableFiltersService
    SKIP_PARAMETERS = %w[f-availability f-subcategories].freeze

    Result = Struct.new(:merge_changed, :reason, keyword_init: true)

    def initialize(category)
      @category = category
    end

    def call
      return Result.new(merge_changed: false, reason: :missing_category) unless @category

      descendant_ids = @category.descendant_ikea_ids
      return Result.new(merge_changed: false, reason: :no_descendants) if descendant_ids.empty?

      merged = build_merged_filters(descendant_ids)
      return Result.new(merge_changed: false, reason: :unchanged) if filters_equal?(@category.available_filters, merged)

      @category.update!(available_filters: merged)
      Result.new(merge_changed: true, reason: :updated)
    end

    private

    def build_merged_filters(descendant_ids)
      descendants = Category.where(ikea_id: descendant_ids).order(:ikea_id).to_a
      # Сначала родитель (имена фильтров и порядок параметров), затем потомки
      categories_to_scan = [@category, *descendants].compact.uniq { |c| c.ikea_id.to_s }

      param_order = []
      filter_names = {}
      values_by_param = Hash.new { |h, k| h[k] = {} }

      categories_to_scan.each do |cat|
        normalize_filters_array(cat.available_filters).each do |filter|
          parameter = filter["parameter"].to_s
          next if parameter.blank?
          next if SKIP_PARAMETERS.include?(parameter)

          param_order << parameter unless param_order.include?(parameter)
          fname = filter["name"].presence || filter["label"].presence
          filter_names[parameter] ||= fname if fname.present?

          Array(filter["values"]).each do |raw|
            next unless raw.is_a?(Hash)

            value = raw.deep_stringify_keys
            vid = value["id"].to_s.presence || value["value_id"].to_s.presence
            next if vid.blank?

            values_by_param[parameter][vid] = merge_value_row(values_by_param[parameter][vid], value)
          end
        end
      end

      # Порядок параметров: как у родителя (если были), иначе порядок первого обнаружения; новые в конец по имени
      parent_params = normalize_filters_array(@category.available_filters).filter_map { |f| f["parameter"].presence&.to_s }.uniq
      ordered_params =
        (parent_params & param_order) + (param_order - parent_params).sort

      ordered_params.filter_map do |parameter|
        bucket = values_by_param[parameter]
        next if bucket.blank?

        rows = bucket.keys.sort.map { |vid| bucket[vid] }
        h = {
          "parameter" => parameter,
          "values" => rows
        }
        h["name"] = filter_names[parameter] if filter_names[parameter].present?
        h
      end
    end

    def merge_value_row(existing, incoming)
      a = (existing || {}).stringify_keys
      b = incoming.stringify_keys
      m = a.merge(b)
      m["name"] = a["name"].presence || b["name"].presence
      if a.key?("label") || b.key?("label")
        m["label"] = a["label"].presence || b["label"].presence
      end
      m
    end

    def normalize_filters_array(raw)
      Array(raw).compact.map do |f|
        f.is_a?(Hash) ? f.deep_stringify_keys : nil
      end.compact
    end

    def filters_equal?(before, after)
      canonical_json(before) == canonical_json(after)
    end

    def canonical_json(filters)
      normalize_filters_array(filters).map do |f|
        param = f["parameter"].to_s
        values = Array(f["values"]).filter_map do |v|
          next unless v.is_a?(Hash)

          h = v.deep_stringify_keys
          id = h["id"].to_s.presence || h["value_id"].to_s.presence
          next if id.blank?

          h.merge("id" => id)
        end.sort_by { |v| v["id"].to_s }

        {
          "parameter" => param,
          "name" => f["name"].to_s,
          "values" => values
        }
      end.sort_by { |x| x["parameter"] }
        .to_json
    end
  end
end
