class CategorySerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id

  attribute :slug do |category|
    category.slug
  end

  attributes :translated_name, 
             :local_image_path, 
             :is_deleted,
             :is_important, 
             :is_popular,
             :is_top,
             :top_position,
             :is_custom,
             :header_menu,
             :header_menu_position,
             :delivery_days,
             :is_bulky,
             :show_delivery_block,
             :show_reviews_block,
             :show_tips_block,
             :icon_url,
             :background_image_url,
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

  attribute :background_image_url do |category|
    if category.background_image.attached?
      begin
        Rails.application.routes.url_helpers.rails_blob_url(category.background_image, only_path: true)
      rescue
        nil
      end
    end
  end

  attribute :parent_ids do |category|
    category.parent_ids || []
  end

  attribute :available_filters do |category|
    category.display_filters
  end

  attribute :seo do |category, params|
    SeoHelper.meta_for(category, params[:city])
  end
end

