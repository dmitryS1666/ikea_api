# frozen_string_literal: true

module Search
  # Текстовый поиск товаров и релевантная сортировка по умолчанию (артикул / id).
  class QueryScope
    CATEGORY_MATCH_LIMIT = 40

    def initialize(query)
      @query = query.to_s.strip
      @terms = QueryTerms.for(@query)
      @term_groups = QueryTerms.groups_for(@query)
    end

    def call
      return Product.none if @query.blank?

      text_scope = direct_text_scope
      category_scope = products_from_matching_categories

      # Keep the search lazy. Calling `exists?` on both branches performed up
      # to two additional database round trips before count/load pagination
      # queries. Both relations are structurally compatible product scopes,
      # and ActiveRecord handles `none` correctly when either branch is empty.
      text_scope.or(category_scope)
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

      and_clauses = []
      binds = {}

      @term_groups.each_with_index do |group, group_index|
        next if group.blank?

        group_clauses = group.each_with_index.map do |term, term_index|
          key = :"group_#{group_index}_term_#{term_index}"
          binds[key] = "%#{term}%"
          fields_match_sql(key)
        end

        and_clauses << "(#{group_clauses.join(' OR ')})" if group_clauses.present?
      end

      if sku_query.present?
        binds[:sku_term] = "%#{sku_query}%"
        sku_clause = "regexp_replace(sku, '[^A-Za-z0-9]', '', 'g') ILIKE :sku_term"
        and_clauses << "(#{sku_clause})" if and_clauses.blank?
      end

      return base.none if and_clauses.blank?

      base.where(and_clauses.join(" AND "), binds)
    end

    def products_from_matching_categories
      ikea_ids = matching_category_ikea_ids
      return Product.none if ikea_ids.blank?

      Product.with_available_stock.in_categories_ikea_ids(ikea_ids)
    end

    def matching_category_ikea_ids
      return [] if @term_groups.blank?

      @term_groups.each_with_index.reduce(nil) do |intersection, (group, group_index)|
        group_ids = category_ids_for_group(group, group_index)
        return [] if group_ids.blank?

        intersection.nil? ? group_ids : (intersection & group_ids)
      end || []
    end

    def text_relevance_sql
      phrase_pattern = ActiveRecord::Base.connection.quote("%#{@query}%")
      phrase_in_name_sql = "name ILIKE #{phrase_pattern} OR name_ru ILIKE #{phrase_pattern}"
      phrase_in_desc_sql = "small_desc_name ILIKE #{phrase_pattern}"
      all_groups_in_name_sql = all_groups_match_sql(%w[name name_ru])
      all_groups_in_desc_sql = all_groups_match_sql(%w[small_desc_name])
      all_groups_anywhere_sql = all_groups_match_sql(%w[name name_ru small_desc_name sku])

      priority_sql = <<~SQL.squish
        CASE
          WHEN #{phrase_in_name_sql} THEN 0
          WHEN #{all_groups_in_name_sql} THEN 1
          WHEN #{phrase_in_desc_sql} THEN 2
          WHEN #{all_groups_in_desc_sql} THEN 3
          WHEN #{all_groups_anywhere_sql} THEN 4
          ELSE 5
        END
      SQL

      "(#{priority_sql} * 1000 + #{fallback_terms_rank_sql})"
    end

    def fallback_terms_rank_sql
      return "0" if @terms.blank?

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

    def fields_match_sql(key)
      <<~SQL.squish
        (name ILIKE :#{key} OR name_ru ILIKE :#{key} OR small_desc_name ILIKE :#{key} OR sku ILIKE :#{key})
      SQL
    end

    def category_ids_for_group(group, group_index)
      return [] if group.blank?

      clauses = []
      binds = {}

      group.each_with_index do |term, term_index|
        key = :"category_#{group_index}_term_#{term_index}"
        binds[key] = "%#{term}%"
        clauses << "(translated_name ILIKE :#{key} OR name ILIKE :#{key})"
      end

      return [] if clauses.blank?

      Category.active
              .where(clauses.join(" OR "), binds)
              .order(Arel.sql("translated_name ASC"))
              .limit(CATEGORY_MATCH_LIMIT)
              .pluck(:ikea_id)
              .map(&:to_s)
              .uniq
    end

    def normalized_sku_query(query)
      query.to_s.gsub(/[^[:alnum:]]/, "")
    end

    def all_groups_match_sql(fields)
      return "FALSE" if @term_groups.blank?

      group_clauses = @term_groups.map do |group|
        next nil if group.blank?

        terms_sql = group.map do |term|
          pattern = ActiveRecord::Base.connection.quote("%#{term}%")
          fields.map { |field| "#{field} ILIKE #{pattern}" }.join(" OR ")
        end

        "(#{terms_sql.map { |condition| "(#{condition})" }.join(' OR ')})"
      end.compact

      return "FALSE" if group_clauses.blank?

      group_clauses.join(" AND ")
    end
  end
end
