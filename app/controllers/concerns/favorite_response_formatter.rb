module FavoriteResponseFormatter
  private

  def favorite_response_payload(favorite, token)
    favorite_items = favorite.favorite_items.includes(:product)

    {
      favorite: {
        token: token || favorite.guest_token,
        expires_at: favorite.expires_at.iso8601,
        items_count: favorite_items.count,
        items: build_favorite_items(favorite_items)
      }
    }
  end

  def build_favorite_items(favorite_items)
    favorite_items.map do |item|
      product = item.product
      {
        sku: public_sku(item.product_sku),
        added_at: item.created_at.iso8601,
        product: product_payload(product)
      }
    end
  end

  def product_payload(product)
    return nil unless product

    {
      sku: public_sku(product.sku),
      name: product.name,
      name_ru: product.name.to_s.presence,
      price_byn: format_byn(
        PriceCalculationService.product_storefront_price_byn(
          product.price,
          weight_kg: product.packaging_weight_kg.to_f,
          delivery_pln: product.delivery_cost.to_f
        )
      ),
      quantity: product.quantity,
      is_favorite: true, # Since it's in favorite list
      category_id: product.category_id,
      collection: product.collection,
      images: {
        local_images: parse_local_images(product.local_images)
      }
    }
  end

  def parse_local_images(images)
    ProductLocalImages.preview_paths(images)
  end

  def public_sku(sku)
    Product.public_sku(sku)
  end

  def format_byn(value)
    sprintf('%.2f', value.to_f)
  end
end
