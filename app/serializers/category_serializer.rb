class CategorySerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id
  
  attributes :ikea_id, :unique_id, :name, :translated_name, :url,
             :remote_image_url, :local_image_path, :is_deleted,
             :is_important, :is_popular, :created_at, :updated_at
  
  attribute :parent_ids do |category|
    category.parent_ids || []
  end
  
  has_many :products, serializer: ProductSerializer
end

