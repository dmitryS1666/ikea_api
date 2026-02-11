class HomeBannerSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :id, 
             :section, 
             :variant, 
             :title, 
             :subtitle, 
             :position, 
             :active
  
  belongs_to :category, serializer: CategorySerializer, if: Proc.new { |record| record.category.present? }
  
  attribute :image_url do |banner, params|
    if banner.image.attached?
      Rails.application.routes.url_helpers.rails_blob_url(banner.image, only_path: true)
    else
      nil
    end
  end
  
  attribute :link_url do |banner|
    if banner.category.present?
      "/categories/#{banner.category.ikea_id}"
    else
      nil
    end
  end
end
