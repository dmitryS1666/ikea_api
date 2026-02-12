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
             :show_tips_block
  
  attribute :parent_ids do |category|
    category.parent_ids || []
  end
end

