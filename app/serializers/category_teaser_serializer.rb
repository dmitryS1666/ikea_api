class CategoryTeaserSerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id

  attributes :translated_name,
             :local_image_path,
             :name

  attribute :slug do |category|
    category.slug
  end
end
