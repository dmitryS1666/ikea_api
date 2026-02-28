class ProductTeaserSerializer
  include FastJsonapi::ObjectSerializer

  attributes :sku,
             :name_ru,
             :slug,
             :price, 
             :quantity, 
             :is_bestseller, 
             :is_new,
             :is_recommended,
             :is_popular,
             :category_id,
             :rating_avg,
             :rating_weighted,
             :rating_count,
             :rating_updated_at,
             :local_images,
             :variants

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    source = product.name_ru.presence || product.name.presence || product.sku
    SlugifyService.call(source)
  end

  attribute :local_images do |product|
    images = product.local_images
    if images.is_a?(String)
      begin
        JSON.parse(images)
      rescue JSON::ParserError
        [images]
      end
    else
      Array(images)
    end
  end

  attribute :variants do |product|
    ProductSerializer.normalize_variants(product.variants)
  end
end
