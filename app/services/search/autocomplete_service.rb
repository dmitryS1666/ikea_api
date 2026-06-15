# frozen_string_literal: true

module Search
  class AutocompleteService
    MIN_QUERY_LENGTH = 2
    SUGGESTION_LIMIT = 5
    CATEGORY_LIMIT = 4
    PRODUCT_LIMIT = 4

    def initialize(query:, params: {})
      @query = query.to_s.strip
      @params = params
    end

    def call
      return empty_payload if @query.length < MIN_QUERY_LENGTH

      category_records = categories_resolver.records
      {
        query: @query,
        normalized_query: normalized_query,
        suggestions: suggestions(category_records),
        categories: category_records.map { |category| serialize_category(category) },
        products: product_records.map { |product| serialize_product(product) }
      }
    end

    private

    def empty_payload
      {
        query: @query,
        normalized_query: normalized_query,
        suggestions: [],
        categories: [],
        products: []
      }
    end

    def suggestions(category_records)
      popular = PopularSearchQuery.active.matching(@query).ordered.limit(SUGGESTION_LIMIT)
      AutocompleteSuggestionsBuilder.new(
        @query,
        popular_queries: popular,
        categories: category_records,
        limit: SUGGESTION_LIMIT
      ).call
    end

    def categories_resolver
      @categories_resolver ||= AutocompleteCategoryResolver.new(
        @query,
        products_scope: text_scope,
        limit: CATEGORY_LIMIT
      )
    end

    def product_records
      @product_records ||= Search::QueryScope.new(@query)
                                            .apply_default_order(text_scope)
                                            .includes(:category)
                                            .limit(PRODUCT_LIMIT)
                                            .to_a
    end

    def text_scope
      @text_scope ||= Search::QueryScope.new(@query).call
    end

    def serialize_category(category)
      {
        id: category.ikea_id.to_s,
        title: category.translated_name.presence || category.name.to_s,
        slug: category.slug,
        url: category.catalog_url,
        local_image_path: category.local_image_path
      }
    end

    def serialize_product(product)
      sku = ProductTeaserSerializer.public_sku(product.sku)
      category = product.primary_category
      title = [product.name_ru.presence || product.name.presence, product.small_desc_name.presence]
              .compact
              .join(" ")
              .squish

      {
        sku: sku,
        slug: product.slug,
        url: product_url(product, sku),
        name_ru: product.name_ru.presence || product.name.presence,
        small_desc_name: product.small_desc_name,
        title: title.presence || product.name.to_s,
        category_title: category&.translated_name.presence || category&.name,
        category_url: category&.catalog_url,
        preview_image: preview_image(product)
      }
    end

    def product_url(product, public_sku)
      slug = product.slug.to_s.presence || public_sku
      "/product/#{slug}-#{public_sku}/"
    end

    def preview_image(product)
      ProductLocalImages.preview_paths(product.local_images).first
    end

    def normalized_query
      @query.downcase
    end
  end
end
