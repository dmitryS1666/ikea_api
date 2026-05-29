# frozen_string_literal: true

module Search
  # Оркестрация /api/v1/search/suggest: текстовый поиск, фильтры, сортировка, подсказки.
  class SuggestService
    SUGGESTION_LIMIT = 5
    CATEGORY_LIMIT = 4

    def initialize(query:, params:, first_page: true)
      @query = query.to_s.strip
      @params = params
      @first_page = first_page
      @page = normalized_page
      @per_page = normalized_per_page
    end

    def text_match_scope
      @text_match_scope ||= Search::QueryScope.new(@query).call
    end

    def filtered_scope
      @filtered_scope ||= begin
        scope = Products::SearchService.new(
          nil,
          search_filter_params,
          base_scope: text_match_scope,
          default_sort: "relevance"
        ).call

        sort_param.present? ? scope : Search::QueryScope.new(@query).apply_default_order(scope)
      end
    end

    def products_relation
      filtered_scope.includes(:category, :categories, :seo_meta)
    end

    def paginated_products
      products_relation.page(@page).per(@per_page)
    end

    def suggestions
      return [] unless @first_page
      return [] if @query.blank?

      popular = PopularSearchQuery.active.matching(@query).ordered.limit(SUGGESTION_LIMIT)
      SuggestionsBuilder.new(@query, popular_queries: popular).call
    end

    def popular_queries
      return [] unless @first_page

      PopularSearchQuery.active.matching(@query).ordered.limit(SUGGESTION_LIMIT)
    end

    def category_records_for_page(products_page)
      return [] unless @first_page

      hashes = SuggestCategoryResolver.new(
        @query,
        products: products_page,
        products_scope: text_match_scope,
        limit: CATEGORY_LIMIT
      ).call

      ids = hashes.filter_map { |entry| entry[:id] || entry["id"] }.map(&:to_s).uniq
      return [] if ids.blank?

      by_id = Category.active.where(ikea_id: ids).index_by { |category| category.ikea_id.to_s }
      ids.filter_map { |ikea_id| by_id[ikea_id] }
    end

    def available_filters(categories)
      return [] unless @first_page

      FiltersAggregator.new(text_match_scope, categories).call
    end

    private

    def normalized_page
      page = @params[:page].to_i
      page.positive? ? page : 1
    end

    def normalized_per_page
      per_page = @params[:per_page].to_i
      per_page = 20 if per_page <= 0
      [per_page, 100].min
    end

    def sort_param
      @params[:sort].to_s.presence
    end

    def search_filter_params
      {
        min_price: @params[:min_price],
        max_price: @params[:max_price],
        sort: sort_param,
        filters: @params[:filters]
      }
    end
  end
end
