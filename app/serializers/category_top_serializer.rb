class CategoryTopSerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id

  attributes :name, 
             :translated_name, 
             :is_top, 
             :top_position,
             :local_image_path,
             :icon_url,
             :pictogram_url

  attribute :slug do |category|
    category.slug
  end

  attribute :icon_url do |category|
    ActiveStorageStaticPublisher.url_for(category.icon)
  end

  attribute :pictogram_url do |category|
    ActiveStorageStaticPublisher.url_for(category.pictogram)
  end
end
