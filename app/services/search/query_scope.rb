# frozen_string_literal: true

module Search
  # Текстовый поиск товаров и релевантная сортировка по умолчанию (артикул / id).
  class QueryScope
    def initialize(query)
      @query = query.to_s.strip
    end

    def call
      return Product.none if @query.blank?

      term = "%#{@query}%"
      sku_query = normalized_sku_query(@query)

      if sku_query.present?
        Product.with_available_stock.where(
          "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term OR regexp_replace(sku, '[^A-Za-z0-9]', '', 'g') ILIKE :sku_term",
          term: term,
          sku_term: "%#{sku_query}%"
        )
      else
        Product.with_available_stock.where(
          "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term",
          term: term
        )
      end
    end

    def apply_default_order(scope)
      return Product.none if @query.blank?

      normalized_query = normalized_sku_query(@query).downcase

      exact_sku_sql = ApplicationRecord.sanitize_sql_array(
        ["CASE WHEN LOWER(regexp_replace(products.sku, '[^A-Za-z0-9]', '', 'g')) = ? THEN 0 ELSE 1 END", normalized_query]
      )

      scope.order(Arel.sql("#{exact_sku_sql}, products.id DESC"))
    end

    private

    def normalized_sku_query(query)
      query.to_s.gsub(/[^[:alnum:]]/, "")
    end
  end
end
