class CategoryPopularSerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id

  attributes :name, 
             :translated_name, 
             :is_popular,
             :local_image_path

  attribute :slug do |category|
    category.slug
  end

  attribute :icon_url do |category|
    if category.icon.attached?
      begin
        Rails.application.routes.url_helpers.rails_blob_url(category.icon, only_path: true)
      rescue
        nil
      end
    end
  end
end
