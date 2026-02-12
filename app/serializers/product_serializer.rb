class ProductSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :sku, 
             :item_no, 
             :name_ru,
             :collection, 
             :price, 
             :quantity, 
             :weight, 
             :net_weight,
             :package_volume, 
             :package_dimensions, 
             :dimensions,
             :is_parcel, 
             :is_bestseller, 
             :is_popular, 
             :category_id,
             :delivery_type, 
             :delivery_name, 
             :delivery_cost,
             :delivery_reason, 
             :breadcrumbs, 
             :seo_title, 
             :seo_h1, 
             :rating_avg, 
             :rating_weighted,
             :rating_count, 
             :rating_updated_at, 
             :short_description_ru,
             :content_ru
  
  attribute :variants do |product|
    product.variants || []
  end
  
  attribute :local_images do |product|
    product.local_images || []
  end
  
  belongs_to :category, serializer: CategorySerializer, if: Proc.new { |record| record.category.present? }
  has_many :categories, serializer: CategorySerializer
  
  attribute :customs_duty, if: ->(_record, params) { params&.dig(:detail) } do |product|
    # Используем текущий курс евро
    eur_rate = ExchangeRate.fetch_or_create('EUR', Date.today)&.rate_per_unit
    pln_rate = ExchangeRate.fetch_or_create('PLN', Date.today)&.rate_per_unit
    
    if eur_rate && pln_rate && product.price && product.weight
      # Конвертируем цену из PLN в EUR для расчета пошлины
      price_eur = (product.price * pln_rate / eur_rate).round(2)
      CustomsDutyService.calculate(price_eur, product.weight, eur_rate)
    else
      nil
    end
  end

  attribute :delivery_days do |product|
    # Приоритет: Категория -> Глобальная настройка -> 30 (fallback)
    product.primary_category&.delivery_days.presence || 
      CalculatorSetting.get('default_delivery_days') || 30
  end

  attribute :display_blocks do |product|
    category = product.category
    
    # Глобальные настройки
    global_delivery = CalculatorSetting.get('show_delivery_block_global') != 0
    global_reviews = CalculatorSetting.get('show_reviews_block_global') != 0
    global_tips = CalculatorSetting.get('show_tips_block_global') != 0

    # Категорийные настройки
    cat_delivery = category&.show_delivery_block != false
    cat_reviews = category&.show_reviews_block != false
    cat_tips = category&.show_tips_block != false
    is_bulky = category&.is_bulky == true

    {
      delivery: global_delivery && cat_delivery,
      reviews: global_reviews && cat_reviews,
      tips: global_tips && cat_tips,
      is_bulky: is_bulky,
      delivery_info: is_bulky ? nil : "Доставка- самовывоз со склада Минск"
    }
  end

  attribute :category_name do |product|
    product.category&.translated_name || product.category&.name || ''
  end

  attribute :seo_title, if: ->(_record, params) { params&.dig(:detail) } do |product|
    Seo::ProductTitleBuilder.build(product, key: "default_title")
  end

  attribute :seo_h1, if: ->(_record, params) { params&.dig(:detail) } do |product|
    Seo::ProductTitleBuilder.build(product, key: "default_h1")
  end

  attribute :breadcrumbs, if: ->(_record, params) { params&.dig(:detail) } do |product|
    Seo::BreadcrumbsBuilder.for_product(product)
  end
end

