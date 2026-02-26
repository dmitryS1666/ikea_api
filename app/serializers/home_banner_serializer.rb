class HomeBannerSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :section, 
             :variant, 
             :position

  attribute :image_url do |banner|
    if banner.image.attached?
      Rails.application.routes.url_helpers.rails_blob_path(banner.image, only_path: true)
    end
  rescue
    nil
  end
  
  attribute :link_url do |banner|
    "/categories/#{banner.category.ikea_id}" if banner.category.present?
  end
end
