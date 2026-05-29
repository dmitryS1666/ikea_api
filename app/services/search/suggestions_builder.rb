# frozen_string_literal: true

module Search
  class SuggestionsBuilder
    SUGGESTION_LIMIT = 5
    ACCESSORY_KEYWORDS = %w[
      чехол аксессуар ножки подушка каркас подлокотник простыня наволочка пододеяльник
      матрас подзор наматрасник ящик изголовье днище покрывало плед одеяло
    ].freeze

    def initialize(query, popular_queries: [])
      @query = query.to_s.strip
      @popular_queries = Array(popular_queries)
    end

    def call
      return [] if @query.blank?

      normalized_query = @query.downcase
      query_suggestions = @popular_queries.map(&:query)
                                          .compact
                                          .map(&:strip)
                                          .reject(&:blank?)
                                          .select { |entry| entry.downcase.include?(normalized_query) }

      return query_suggestions.uniq.first(SUGGESTION_LIMIT) if query_suggestions.size >= SUGGESTION_LIMIT

      term = "%#{@query}%"
      top_matching_categories = Category.active.where("translated_name ILIKE ?", "#{@query}%").pluck(:ikea_id).map(&:to_s)

      products = Product.with_available_stock.where(
        "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term",
        term: term
      ).limit(100)

      product_suggestions = products.filter_map do |product|
        display_name = product.small_desc_name.presence || product.name_ru.presence || product.name.presence
        next if display_name.blank?

        is_accessory = ACCESSORY_KEYWORDS.any? { |keyword| display_name.downcase.include?(keyword) }
        priority = is_accessory ? 1 : 0
        priority -= 2 if top_matching_categories.include?(product.category_id.to_s)
        priority -= 1 if display_name.downcase.start_with?(@query.downcase)
        priority -= 1 if display_name.downcase.include?(" #{@query.downcase}")

        { name: display_name.strip, priority: priority }
      end.uniq { |entry| entry[:name] }
         .sort_by { |entry| [entry[:priority], entry[:name]] }
         .first(SUGGESTION_LIMIT)
         .pluck(:name)

      (query_suggestions + product_suggestions).uniq.first(SUGGESTION_LIMIT)
    end
  end
end
