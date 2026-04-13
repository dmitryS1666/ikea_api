# frozen_string_literal: true

# Список товаров категории для задачи refresh_category_lt:
# 1) список SKU всегда берём с PL-витрины (ikea.com/pl/pl/cat/...),
# 2) если HTML-листинг пустой (новая CSR-разметка) — fallback на IKEA search API.
# LT при этом используется отдельно для расширенных описательных атрибутов товара.
class CategoryLtListingService
  class << self
    def pl_listing_url(category)
      raw = category.url.to_s.strip
      if raw.blank?
        # Если ikea_id числовой, строим URL по шаблону
        if category.ikea_id.to_s.match?(/\A\d+\z/)
          return "https://www.ikea.com/pl/pl/cat/#{category.ikea_id}/"
        end

        Rails.logger.warn "CategoryLtListingService: category #{category.ikea_id} has no url — cannot build PL listing URL"
        return nil
      end

      path =
        if raw.start_with?("http://", "https://")
          URI.parse(raw).path
        else
          raw.start_with?("/") ? raw : "/#{raw}"
        end

      pl_path = path.gsub(%r{/lt/ru/}, "/pl/pl/")
      "https://www.ikea.com#{pl_path}"
    end

    # Backward compatibility for existing calls in jobs/admin.
    alias_method :lt_listing_url, :pl_listing_url

    def fetch_page(category, offset:, limit:)
      listing = pl_listing_url(category)
      return [] if listing.blank?

      rows = CategoryProductsFetcher.fetch(listing, offset: offset, limit: limit)
      return rows if rows.present?

      # Новые витрины ikea.com часто отдают HTML без встроенного productList — только hydration/{}.
      # Тогда список SKU берём из поискового API IKEA (CATEGORY + числовой ikea_id).
      Rails.logger.info(
        "CategoryLtListingService: HTML listing empty (#{listing}), fallback IkeaApiService " \
        "category=#{category.ikea_id} offset=#{offset} limit=#{limit}"
      )
      IkeaApiService.search_products_by_category(category.ikea_id.to_s, offset: offset, limit: limit)
    end
  end
end
