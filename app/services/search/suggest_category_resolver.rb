# frozen_string_literal: true

module Search
  # Категории для блока «Категории» в /api/v1/search/suggest.
  # Подкатегории не прячутся под родителем: в подсказках каждая релевантная
  # категория — отдельный корневой пункт (children: []).
  class SuggestCategoryResolver
    CATEGORY_LIMIT = 10
    PRODUCT_CATEGORY_SAMPLE = 50
    # Подстрока «расклад» в «нерасклад*» даёт ложное совпадение — опускаем вниз, если запрос не про нерасклад.
    NON_FOLDING_NAME_MARKERS = %w[нерасклад нерозклад nierozkład nierozklad].freeze

    def initialize(query, products: [], products_scope: nil, limit: CATEGORY_LIMIT)
      @query = query.to_s.strip
      @products = Array(products)
      @products_scope = products_scope
      @limit = limit.to_i.positive? ? limit.to_i : CATEGORY_LIMIT
    end

    def call
      return [] if @query.blank?

      matched = matching_categories
      from_products = deepest_categories_from_products
      combined = deepest_categories_only(matched + from_products)

      sort_categories(combined, matched_ids: matched.map { |c| c.ikea_id.to_s }.to_set)
        .first(@limit)
        .map { |category| serialize_category(category) }
    end

    private

    def matching_categories
      term = "%#{@query}%"
      starts_with_term = "#{@query}%"
      sanitized_pattern = Category.connection.quote(starts_with_term)

      Category.active
              .where(category_match_sql, term: term)
              .order(Arel.sql(<<~SQL.squish))
                CASE
                  WHEN translated_name ILIKE #{sanitized_pattern} THEN 0
                  WHEN name ILIKE #{sanitized_pattern} THEN 1
                  ELSE 2
                END,
                #{category_depth_sql} DESC,
                translated_name ASC
              SQL
              .limit(CATEGORY_LIMIT * 2)
              .to_a
    end

    def category_match_sql
      <<~SQL.squish
        name ILIKE :term
        OR translated_name ILIKE :term
        OR available_filters::text ILIKE :term
        OR COALESCE(available_filters_ru, '[]'::jsonb)::text ILIKE :term
      SQL
    end

    def category_depth_sql
      <<~SQL.squish
        CASE
          WHEN parent_ids IS NULL OR parent_ids::text IN ('[]', '""', '') THEN 0
          ELSE COALESCE(jsonb_array_length(parent_ids::jsonb), 0)
        END
      SQL
    end

    def deepest_categories_from_products
      ids = category_ids_from_products
      ids = category_ids_from_scope if ids.blank? && @products_scope.present?
      return [] if ids.blank?

      deepest_categories_only(Category.active.where(ikea_id: ids).to_a)
    end

    def category_ids_from_products
      return [] if @products.blank?

      @products.flat_map { |product| product_category_ids(product) }.compact.uniq
    end

    def product_category_ids(product)
      ids = product.categories.map { |c| c.ikea_id.to_s }
      ids << product.category_id.to_s if product.category_id.present?
      ids.reject(&:blank?).uniq
    end

    def category_ids_from_scope
      scope = @products_scope
      return [] unless scope

      product_ids = scope.limit(PRODUCT_CATEGORY_SAMPLE * 5).select(:id)
      primary_ids = scope.distinct.limit(PRODUCT_CATEGORY_SAMPLE).pluck(:category_id).compact.map(&:to_s)
      linked_ids = CategoryProduct.where(product_id: product_ids)
                                  .distinct
                                  .limit(PRODUCT_CATEGORY_SAMPLE * 3)
                                  .pluck(:category_id)
                                  .map(&:to_s)
      filter_ids = ProductFilterValue.where(product_id: product_ids)
                                     .distinct
                                     .limit(PRODUCT_CATEGORY_SAMPLE * 3)
                                     .pluck(:category_id)
                                     .map(&:to_s)
      subcategory_ids = subcategory_ids_for_parents(primary_ids + linked_ids, scope)

      (primary_ids + linked_ids + filter_ids + subcategory_ids).uniq
    end

    # Если товары привязаны к родительской категории, подтягиваем прямых потомков,
    # в которых тоже есть совпадения по запросу (типичный случай fu003 под 700640).
    def subcategory_ids_for_parents(parent_ids, scope)
      parent_ids = parent_ids.compact.uniq
      return [] if parent_ids.blank?

      children = Category.active.where(
        <<~SQL.squish,
          parent_ids IS NOT NULL
          AND parent_ids::text NOT IN ('[]', '""', '')
          AND (parent_ids::jsonb ->> (jsonb_array_length(parent_ids::jsonb) - 1)) IN (?)
        SQL
        parent_ids
      )
      child_ikea_ids = children.pluck(:ikea_id)
      return [] if child_ikea_ids.blank?

      product_ids = scope.select(:id)
      from_primary = scope.where(category_id: child_ikea_ids).distinct.pluck(:category_id)
      from_linked = CategoryProduct.where(category_id: child_ikea_ids, product_id: product_ids).distinct.pluck(:category_id)

      (from_primary + from_linked).map(&:to_s).uniq
    end

    def deepest_categories_only(categories)
      return [] if categories.blank?

      list = categories.compact.uniq { |c| c.ikea_id.to_s }
      list.reject do |category|
        list.any? do |other|
          other.ikea_id.to_s != category.ikea_id.to_s &&
            descendant_of?(ancestor: category, descendant: other)
        end
      end
    end

    def descendant_of?(ancestor:, descendant:)
      Category.normalize_parent_ids(descendant.parent_ids).include?(ancestor.ikea_id.to_s)
    end

    def sort_categories(categories, matched_ids:)
      lower_query = @query.downcase

      categories.sort_by do |category|
        name = display_name(category).downcase
        priority =
          if matched_ids.include?(category.ikea_id.to_s) && name.start_with?(lower_query)
            0
          elsif matched_ids.include?(category.ikea_id.to_s) || name.include?(lower_query)
            1
          else
            2
          end

        depth = -Category.normalize_parent_ids(category.parent_ids).size
        non_folding_tail = non_folding_false_positive?(name, lower_query) ? 1 : 0

        [priority, non_folding_tail, depth, name]
      end
    end

    def non_folding_false_positive?(name, lower_query)
      return false if query_about_non_folding?(lower_query)
      return false unless non_folding_category_name?(name)

      # «раскладные» попадает в «нераскладные» только как подстрока, не как отдельное слово.
      lower_query.present? && name.include?(lower_query) && !name.start_with?(lower_query)
    end

    def query_about_non_folding?(lower_query)
      NON_FOLDING_NAME_MARKERS.any? { |marker| lower_query.include?(marker) }
    end

    def non_folding_category_name?(name)
      NON_FOLDING_NAME_MARKERS.any? { |marker| name.include?(marker) }
    end

    def serialize_category(category)
      {
        id: category.ikea_id,
        slug: category.slug,
        translated_name: category.translated_name,
        local_image_path: category.local_image_path,
        children: []
      }
    end

    def display_name(category)
      category.translated_name.presence || category.name
    end
  end
end
