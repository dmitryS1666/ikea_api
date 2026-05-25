# frozen_string_literal: true

module Products
  # Единая точка сборки публичных URL товара.
  #
  # Внутренний SKU в БД может быть сохранён как `79578593` или как listing-SKU
  # `s79578593`. Во внешнем URL используем чистый артикул без `s`, чтобы карточка
  # имела стабильный вид `/product/saltsjobaden-79578593/` и совпадала с SEO/schema.
  module PublicProductUrl
    module_function

    def sku_core(raw_sku)
      raw_sku.to_s.strip.sub(/\As/i, "")
    end

    def path(product)
      return nil unless product

      core = sku_core(product.sku)
      return nil if core.blank?

      slug = product.slug.to_s.presence || core
      "/product/#{slug}-#{core}/"
    end

    def url(product, site_url:)
      product_path = path(product)
      return nil if product_path.blank?

      "#{site_url.to_s.chomp("/")}#{product_path}"
    end
  end
end
