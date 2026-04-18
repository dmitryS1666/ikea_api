# frozen_string_literal: true

# Полная догрузка товара-варианта (PL+LT, варианты PIP, локальные картинки) и привязка к категории.
# Ставится в очередь из Products::VariantProductsEnsureService для SKU из variants_payload.
class EnrichVariantProductJob < ApplicationJob
  queue_as :parser
  LOCK_TTL = 2.hours

  class << self
    def enqueue_once(sku:, category_ikea_id: nil)
      normalized_sku = normalize_sku(sku)
      return false if normalized_sku.blank?

      normalized_category_ikea_id = normalize_category_ikea_id(category_ikea_id)
      lock_key = dedupe_key(normalized_sku, normalized_category_ikea_id)
      locked = Sidekiq.redis { |redis| redis.set(lock_key, 1, nx: true, ex: LOCK_TTL.to_i) }
      return false unless locked

      perform_later(sku: normalized_sku, category_ikea_id: normalized_category_ikea_id)
      true
    rescue StandardError => e
      release_enqueue_lock(sku: normalized_sku, category_ikea_id: normalized_category_ikea_id) if normalized_sku.present?
      Rails.logger.warn "EnrichVariantProductJob enqueue_once sku=#{sku}: #{e.class} #{e.message}"
      raise
    end

    def release_enqueue_lock(sku:, category_ikea_id: nil)
      normalized_sku = normalize_sku(sku)
      return if normalized_sku.blank?

      normalized_category_ikea_id = normalize_category_ikea_id(category_ikea_id)
      Sidekiq.redis { |redis| redis.del(dedupe_key(normalized_sku, normalized_category_ikea_id)) }
    rescue StandardError => e
      Rails.logger.warn "EnrichVariantProductJob release lock sku=#{sku}: #{e.class} #{e.message}"
    end

    private

    def dedupe_key(sku, category_ikea_id)
      "enrich_variant_product_job:#{category_ikea_id.presence || 'none'}:#{sku}"
    end

    def normalize_sku(sku)
      sku.to_s.strip.presence
    end

    def normalize_category_ikea_id(category_ikea_id)
      category_ikea_id.to_s.strip.presence
    end
  end

  def perform(sku:, category_ikea_id: nil)
    sku = self.class.send(:normalize_sku, sku)
    category_ikea_id = self.class.send(:normalize_category_ikea_id, category_ikea_id)
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
  rescue StandardError => e
    Rails.logger.error "EnrichVariantProductJob sku=#{sku}: #{e.class} #{e.message}"
    raise
  ensure
    self.class.release_enqueue_lock(sku: sku, category_ikea_id: category_ikea_id) if sku.present?
  end
end
