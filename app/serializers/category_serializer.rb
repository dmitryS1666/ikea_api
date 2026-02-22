class CategorySerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id
  
  attributes :translated_name, 
             :local_image_path, 
             :is_deleted,
             :is_important, 
             :is_popular,
             :header_menu,
             :header_menu_position,
             :delivery_days,
             :is_bulky,
             :show_delivery_block,
             :show_reviews_block,
             :show_tips_block,
            :icon_url,
            :available_filters
  
  attribute :icon_url do |category|
    if category.icon.attached?
      begin
        Rails.application.routes.url_helpers.rails_blob_url(category.icon, only_path: true)
      rescue
        nil
      end
    end
  end

  attribute :parent_ids do |category|
    category.parent_ids || []
  end

  attribute :available_filters do |category|
    category.available_filters || []
  end

  attribute :seo do |category, params|
    SeoHelper.meta_for(category, params[:city])
  end
end

