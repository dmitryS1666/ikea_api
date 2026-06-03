# frozen_string_literal: true

module Search
  class AutocompleteCategoryResolver
    DEFAULT_LIMIT = 4
    MATCH_LIMIT = 30

    def initialize(query, products_scope: nil, limit: DEFAULT_LIMIT)
      @query = query.to_s.strip
      @products_scope = products_scope
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
      @terms = QueryTerms.for(@query)
    end

    def records
      return [] if @query.blank?

      combined = matching_categories + categories_from_products
      sort_categories(combined.uniq { |category| category.ikea_id.to_s }).first(@limit)
    end

    def call
      records.map { |category| serialize_category(category) }
    end

    private

    def matching_categories
      return [] if @terms.blank?

      clauses = []
      binds = {}
      @terms.each_with_index do |term, index|
        key = :"term_#{index}"
        binds[key] = "%#{term}%"
        clauses << "translated_name ILIKE :#{key} OR name ILIKE :#{key}"
      end

      Category.active
              .where(clauses.map { |clause| "(#{clause})" }.join(" OR "), binds)
              .limit(MATCH_LIMIT)
              .to_a
    end

    def categories_from_products
      return [] unless @products_scope

      product_ids = @products_scope.limit(40).select(:id)
      primary_ids = @products_scope.limit(40).pluck(:category_id).compact.map(&:to_s)
      linked_ids = CategoryProduct.where(product_id: product_ids).distinct.limit(80).pluck(:category_id).map(&:to_s)
      ids = (primary_ids + linked_ids).reject(&:blank?).uniq
      return [] if ids.blank?

      Category.active.where(ikea_id: ids).to_a
    end

    def sort_categories(categories)
      lower_query = @query.downcase
      lower_terms = @terms.map(&:downcase)

      categories.sort_by do |category|
        title = display_name(category).downcase
        priority =
          if title == lower_query || lower_terms.include?(title)
            0
          elsif title.start_with?(lower_query) || lower_terms.any? { |term| title.start_with?(term) }
            1
          elsif title.include?(lower_query) || lower_terms.any? { |term| title.include?(term) }
            2
          else
            3
          end

        depth = -Category.normalize_parent_ids(category.parent_ids).size
        [priority, depth, title]
      end
    end

    def serialize_category(category)
      {
        id: category.ikea_id.to_s,
        title: display_name(category),
        slug: category.slug,
        url: category.catalog_url,
        local_image_path: category.local_image_path
      }
    end

    def display_name(category)
      category.translated_name.presence || category.name.to_s
    end
  end
end
