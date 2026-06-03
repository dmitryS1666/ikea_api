# frozen_string_literal: true

module Search
  class AutocompleteSuggestionsBuilder
    DEFAULT_LIMIT = 5
    MAX_TITLE_LENGTH = 64

    STATIC_BY_TERM = {
      "шкаф" => ["Шкафы", "Шкафы для одежды", "Шкаф PAX", "Гардероб", "Гардероб PAX"],
      "шкафы" => ["Шкафы", "Шкафы для одежды", "Шкаф PAX", "Гардероб", "Гардероб PAX"],
      "гардероб" => ["Гардероб", "Гардероб PAX", "Шкафы", "Шкафы для одежды"],
      "pax" => ["PAX", "PAX гардероб", "Шкаф PAX"],
      "пакс" => ["ПАКС", "ПАКС гардероб", "Шкаф ПАКС"],
      "диван" => ["Диван", "Диван раскладной", "Диван угловой", "Диван угловой на кухню", "Диван-кровать"],
      "диваны" => ["Диван", "Диван раскладной", "Диван угловой", "Диван угловой на кухню", "Диван-кровать"],
      "кровать" => ["Кровать", "Кровать двуспальная", "Кровать с ящиками", "Каркас кровати"],
      "кровати" => ["Кровать", "Кровать двуспальная", "Кровать с ящиками", "Каркас кровати"]
    }.freeze

    def initialize(query, popular_queries: [], categories: [], limit: DEFAULT_LIMIT)
      @query = query.to_s.strip
      @popular_queries = Array(popular_queries)
      @categories = Array(categories)
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
    end

    def call
      return [] if @query.blank?

      (popular_query_titles + static_titles + category_titles)
        .map { |title| normalize_title(title) }
        .reject(&:blank?)
        .uniq { |title| title.downcase }
        .first(@limit)
        .map { |title| { title: title, query: title.downcase } }
    end

    private

    def popular_query_titles
      normalized = normalized_query
      @popular_queries.map(&:query)
                      .compact
                      .map(&:strip)
                      .reject(&:blank?)
                      .select { |entry| entry.downcase.include?(normalized) }
    end

    def static_titles
      keys = [normalized_query] + QueryTerms.for(@query).map(&:downcase)
      keys.uniq.flat_map { |key| STATIC_BY_TERM[key] || [] }
    end

    def category_titles
      @categories.filter_map do |category|
        title = category_title(category)
        next if title.blank?
        next if title.length > MAX_TITLE_LENGTH

        title
      end
    end

    def category_title(category)
      if category.respond_to?(:translated_name)
        category.translated_name.presence || category.name.presence
      else
        category[:title].presence || category["title"].presence ||
          category[:translated_name].presence || category["translated_name"].presence
      end
    end

    def normalize_title(title)
      title.to_s.squish
    end

    def normalized_query
      @query.downcase
    end
  end
end
