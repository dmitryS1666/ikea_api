# frozen_string_literal: true

module Products
  # Единая точка сборки публичных URL товара.
  #
  # Внутренний SKU в БД может быть сохранён как `79578593` или как listing-SKU
  # `s79578593`. Во внешнем URL используем чистый артикул без `s`, чтобы карточка
  # имела стабильный вид `/product/saltsjobaden-79578593/` и совпадала с SEO/schema.
  module PublicProductUrl
    module_function

    MAX_SLUG_LENGTH = 80

    def sku_core(raw_sku)
      raw_sku.to_s.strip.sub(/\As/i, "")
    end

    # Канонический slug для публичного URL.
    #
    # Защищает витрину от повреждённых cached_slug/name, например:
    #   landskrona-landskrona-landskrona-...-s39491276
    #
    # В URL оставляем короткую стабильную часть + чистый артикул. SKU остаётся
    # внутренним и не меняется.
    def public_slug(product)
      return nil unless product

      source =
        if product.respond_to?(:cached_slug) && product.cached_slug.present?
          product.cached_slug
        else
          product.name_ru.presence || product.name.presence || product.small_desc_name.presence
        end

      normalized_slug(source).presence || sku_core(product.sku)
    end

    def normalized_slug(value)
      slug = SlugifyService.call(value)
      return nil if slug.blank?

      tokens = slug.split("-").reject(&:blank?)
      tokens = collapse_repeated_tokens(tokens)
      truncate_tokens(tokens, MAX_SLUG_LENGTH).join("-").presence
    end

    def collapse_repeated_tokens(tokens)
      collapsed = []
      tokens.each do |token|
        collapsed << token unless collapsed.last == token
      end
      collapsed
    end

    def truncate_tokens(tokens, max_length)
      result = []
      tokens.each do |token|
        candidate = (result + [token]).join("-")
        break if result.any? && candidate.length > max_length

        result << token
        break if candidate.length >= max_length
      end
      result.presence || tokens.first(1)
    end

    def path(product)
      return nil unless product

      core = sku_core(product.sku)
      return nil if core.blank?

      slug = public_slug(product).presence || core
      "/product/#{slug}-#{core}/"
    end

    def url(product, site_url:)
      product_path = path(product)
      return nil if product_path.blank?

      "#{site_url.to_s.chomp("/")}#{product_path}"
    end
  end
end
