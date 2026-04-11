# frozen_string_literal: true

# Полная догрузка товара-варианта (PL+LT, варианты PIP, локальные картинки) и привязка к категории.
# Ставится в очередь из Products::VariantProductsEnsureService для SKU из variants_payload.
class EnrichVariantProductJob < ApplicationJob
  queue_as :parser

  def perform(sku:, category_ikea_id: nil)
    sku = sku.to_s.strip
    return if sku.blank?

    product = Products::ListingSkuResolver.find_product(sku) || Product.find_by(sku: sku)
    return unless product

    if category_ikea_id.present?
      CategoryProduct.find_or_create_by!(product: product, category_id: category_ikea_id.to_s)
    end

    Products::ExtendedAttributesFetchService.fetch_for_product(product)
    IkeaLvProductVariantsService.new(product: product, force: true).call

    product.reload
    if Array(product.images).compact.reject(&:blank?).any?
      ImageDownloader.sync_product_images(product)
    end

    cat = Category.find_by(ikea_id: category_ikea_id.to_s) if category_ikea_id.present?
    if cat.present? && product.reload.variants_payload.present?
      Products::VariantProductsEnsureService.ensure!(product, category: cat)
    end
  rescue StandardError => e
    Rails.logger.error "EnrichVariantProductJob sku=#{sku}: #{e.class} #{e.message}"
    raise
  end
end
