# Сериализатор для карты категорий
# Возвращает категории с переведенными именами, ссылками и продуктами
class CategoryMapSerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id
  
  attributes :ikea_id, :name, :translated_name, :url
  
  attribute :products do |category|
    category.products_with_available_stock.map do |product|
      {
        sku: product.sku,
        name: product.name,
        name_ru: product.name.to_s.presence,
        url: product.url
      }
    end
  end
end

