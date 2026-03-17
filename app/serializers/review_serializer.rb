class ReviewSerializer
  include FastJsonapi::ObjectSerializer

  attributes :id, :product_sku, :rating, :body, :status,
             :pinned, :excluded_from_rating, :admin_note,
             :created_at, :published_at

  attribute :helpful_count do |review|
    review.helpful_count
  end

  attribute :photos do |review|
    review.photos_urls
  end

  attribute :product do |review|
    product = review.product
    {
      sku: product&.sku,
      name: product&.name,
      images: product&.images || [],
      local_images: product&.local_images || []
    }
  end
end
