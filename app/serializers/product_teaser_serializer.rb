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

  attribute :slug do |product|
    source = product.name_ru.presence || product.name.presence || product.sku
    SlugifyService.call(source)
  end

  attribute :local_images do |product|
    product.local_images || []
  end

  attribute :variants do |product|
    ProductSerializer.normalize_variants(product.variants)
  end
end
