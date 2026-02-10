class CategorySerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id
  
  attributes :translated_name, 
             :local_image_path, 
             :is_deleted,
             :is_important, 
             :is_popular
  
  attribute :parent_ids do |category|
    category.parent_ids || []
  end
  
  has_many :products, serializer: ProductSerializer
end

