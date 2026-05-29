# frozen_string_literal: true

module Search
  # Текстовый поиск товаров и релевантная сортировка по умолчанию (артикул / id).
  class QueryScope
    CATEGORY_MATCH_LIMIT = 40

    def initialize(query)
      @query = query.to_s.strip
      @terms = QueryTerms.for(@query)
    end

    def call
      return Product.none if @query.blank?

      text_scope = direct_text_scope
      category_scope = products_from_matching_categories

      return text_scope unless category_scope.exists?
      return category_scope unless text_scope.exists?

      Product.with_available_stock.where(id: text_scope.select(:id))
             .or(Product.with_available_stock.where(id: category_scope.select(:id)))
    end

    def apply_default_order(scope)
      return Product.none if @query.blank?

      normalized_query = normalized_sku_query(@query).downcase
      text_rank_sql = text_relevance_sql

      exact_sku_sql = ApplicationRecord.sanitize_sql_array(
        ["CASE WHEN LOWER(regexp_replace(products.sku, '[^A-Za-z0-9]', '', 'g')) = ? THEN 0 ELSE 1 END", normalized_query]
      )

      scope.order(Arel.sql("#{exact_sku_sql}, #{text_rank_sql}, products.id DESC"))
    end

    private

    def direct_text_scope
      base = Product.with_available_stock
      sku_query = normalized_sku_query(@query)

      clauses = []
      binds = {}

      @terms.each_with_index do |term, index|
        key = :"term_#{index}"
        binds[key] = "%#{term}%"
        clauses << <<~SQL.squish
          (name ILIKE :#{key} OR name_ru ILIKE :#{key} OR small_desc_name ILIKE :#{key} OR sku ILIKE :#{key})
        SQL
      end

      if sku_query.present?
        binds[:sku_term] = "%#{sku_query}%"
        clauses << "regexp_replace(sku, '[^A-Za-z0-9]', '', 'g') ILIKE :sku_term"
      end

      base.where(clauses.join(" OR "), binds)
    end

    def products_from_matching_categories
      ikea_ids = matching_category_ikea_ids
      return Product.none if ikea_ids.blank?

      Product.with_available_stock.in_categories_ikea_ids(ikea_ids)
    end

    def matching_category_ikea_ids
      ids = []

      @terms.each do |term|
        ids.concat(
          Category.active
                  .where("translated_name ILIKE :term OR name ILIKE :term", term: "%#{term}%")
                  .order(Arel.sql("translated_name ASC"))
                  .limit(CATEGORY_MATCH_LIMIT)
                  .pluck(:ikea_id)
        )
      end

      ids.map(&:to_s).uniq
    end

    def text_relevance_sql
      parts = @terms.each_with_index.map do |term, index|
        sanitized = ActiveRecord::Base.connection.quote("%#{term}%")
        <<~SQL.squish
          CASE
            WHEN name ILIKE #{sanitized} OR name_ru ILIKE #{sanitized} OR small_desc_name ILIKE #{sanitized} THEN #{index}
            ELSE #{@terms.length + index}
          END
        SQL
      end

      "(#{parts.join(" + ")})"
    end

    def normalized_sku_query(query)
      query.to_s.gsub(/[^[:alnum:]]/, "")
    end
  end
end
