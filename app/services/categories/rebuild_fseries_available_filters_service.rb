# frozen_string_literal: true

module Categories
  # Собирает уникальные серии (f-series) из товаров категории и всего поддерева,
  # обновляет available_filters без дублей и без префикса «Серия » в name.
  class RebuildFseriesAvailableFiltersService
    F_SERIES = "f-series"

    Result = Struct.new(
      :changed,
      :series_count,
      :products_scanned,
      :categories_updated,
      :propagate_to_descendants,
      keyword_init: true
    )

    def initialize(category, propagate_to_descendants: true)
      @category = category
      @propagate_to_descendants = propagate_to_descendants
    end

    def call
      return Result.new(changed: false, series_count: 0, products_scanned: 0, categories_updated: 0) unless @category

      tree_ids = @category.self_and_descendant_ikea_ids
      products_scope = Product.in_categories_ikea_ids(tree_ids).active.with_available_stock

      labels_by_key = Hash.new { |h, k| h[k] = [] }
      existing_by_key = load_existing_rows_by_key(tree_ids)
      products_scanned = 0

      products_scope.find_each do |product|
        products_scanned += 1
        Products::SeriesDiscovery.raw_labels_from_product(product).each do |label|
          key = Products::SeriesFilterNormalization.normalize_key(label)
          next if key.blank?

          labels_by_key[key] << label
        end
      end

      existing_by_key.each_key { |key| labels_by_key[key] ||= [] }

      f_series_filter = build_f_series_filter(labels_by_key, existing_by_key)
      series_count = Array(f_series_filter["values"]).size

      categories_updated = apply_f_series_filter!(tree_ids, f_series_filter)

      Result.new(
        changed: categories_updated.positive?,
        series_count: series_count,
        products_scanned: products_scanned,
        categories_updated: categories_updated,
        propagate_to_descendants: @propagate_to_descendants
      )
    end

    private

    def load_existing_rows_by_key(tree_ids)
      by_key = {}

      Category.where(ikea_id: tree_ids).find_each do |cat|
        f_series_values(cat.available_filters).each do |row|
          key = Products::SeriesFilterNormalization.normalize_key(row["name"].presence || row["id"])
          next if key.blank?

          by_key[key] ||= []
          by_key[key] << row unless by_key[key].any? { |r| r["id"] == row["id"] }
        end
      end

      by_key
    end

    def build_f_series_filter(labels_by_key, existing_by_key)
      values = labels_by_key.keys.sort.filter_map do |key|
        build_value_row(key, labels_by_key[key], existing_by_key[key])
      end

      filter_name = f_series_filter_name

      {
        "parameter" => F_SERIES,
        "name" => filter_name,
        "values" => values
      }
    end

    def build_value_row(normalized_key, raw_labels, existing_rows)
      candidate_rows = Array(existing_rows).map { |r| r.deep_stringify_keys }
      raw_labels.each do |label|
        candidate_rows << { "id" => provisional_id(label, normalized_key), "name" => label }
      end

      canonical = Products::SeriesFilterNormalization.pick_canonical_value_row(candidate_rows)
      return nil unless canonical

      id = stable_value_id(normalized_key, canonical, existing_rows)
      display = Products::SeriesFilterNormalization.display_name(canonical["name"].presence || canonical["id"])
      display = normalized_key if display.blank?

      { "id" => id, "name" => display }
    end

    def stable_value_id(normalized_key, canonical, existing_rows)
      Array(existing_rows).each do |row|
        id = row["id"].to_s.presence
        return id if id.present?
      end

      id = canonical["id"].to_s.presence
      return id if id.match?(/\A\d+\z/)
      return id if Products::SeriesFilterNormalization.normalize_key(id) == normalized_key

      normalized_key
    end

    def provisional_id(label, normalized_key)
      stripped = Products::SeriesFilterNormalization.display_name(label)
      token = stripped.to_s.gsub(/[^A-Z0-9]/i, "").upcase
      token.presence || normalized_key
    end

    def f_series_filter_name
      f_series_values(@category.available_filters).first&.dig("name").presence ||
        f_series_filter_from_tree&.dig("name").presence ||
        "Серия"
    end

    def f_series_filter_from_tree
      tree_ids = @category.self_and_descendant_ikea_ids
      Category.where(ikea_id: tree_ids).order(:ikea_id).each do |cat|
        filter = normalize_filters(cat.available_filters).find { |f| f["parameter"] == F_SERIES }
        return filter if filter.present?
      end
      nil
    end

    def apply_f_series_filter!(tree_ids, f_series_filter)
      target_ids =
        if @propagate_to_descendants
          tree_ids
        else
          [@category.ikea_id.to_s]
        end

      updated = 0
      Category.where(ikea_id: target_ids).find_each do |cat|
        filters = normalize_filters(cat.available_filters)
        next if filters_equal_f_series?(filters, f_series_filter)

        filters = filters.reject { |f| f["parameter"] == F_SERIES }
        filters << f_series_filter
        cat.update!(available_filters: filters)
        updated += 1
      end

      updated
    end

    def filters_equal_f_series?(filters, f_series_filter)
      current = filters.find { |f| f["parameter"] == F_SERIES }
      return false if current.blank?

      canonical_json(current) == canonical_json(f_series_filter)
    end

    def canonical_json(filter)
      f = filter.deep_stringify_keys
      values = Array(f["values"]).map do |v|
        h = v.deep_stringify_keys
        { "id" => h["id"].to_s, "name" => h["name"].to_s }
      end.sort_by { |v| v["id"] }

      { "parameter" => f["parameter"], "name" => f["name"].to_s, "values" => values }.to_json
    end

    def f_series_values(filters)
      filter = normalize_filters(filters).find { |f| f["parameter"] == F_SERIES }
      Array(filter&.dig("values")).filter_map do |v|
        next unless v.is_a?(Hash)

        v.deep_stringify_keys
      end
    end

    def normalize_filters(raw)
      Array(raw).compact.map do |f|
        f.is_a?(Hash) ? f.deep_stringify_keys : nil
      end.compact
    end
  end
end
