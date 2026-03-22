class HomeBannerSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :section, 
             :variant, 
             :position,
             :active,
             :created_at,
             :updated_at

  attribute :image_url do |banner|
    if banner.image.attached?
      Rails.application.routes.url_helpers.rails_blob_path(banner.image, only_path: true)
    end
  rescue
    nil
  end
  
  attribute :link_url do |banner|
    banner.final_link
  end
end
