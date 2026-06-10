# frozen_string_literal: true

class OrderItemImageSnapshot
  class << self
    def for_order_item(order_item)
      snapshot_url = first_public_image_url(order_item.image_url) if order_item.respond_to?(:image_url)
      return snapshot_url if snapshot_url.present?

      for_product(order_item.product)
    end

    def for_product(product)
      return nil unless product

      local_url = first_public_image_url(product.local_images)
      return local_url if local_url.present?

      first_public_image_url(product.images)
    end

    def first_public_image_url(value)
      ProductLocalImages.expand_paths(value).find(&:present?)
    rescue StandardError => e
      Rails.logger.warn("OrderItemImageSnapshot: failed to normalize image URL: #{e.class} #{e.message}")
      nil
    end
  end
end
