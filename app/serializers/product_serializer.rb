class ProductSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :sku,
             :name_ru,
             :slug,
             :price, 
             :price_pln,
             :price_byn,
             :quantity, 
             :weight,
             :is_bestseller, 
             :is_new,
             :is_recommended,
             :is_popular, 
             :category_id,
             :rating_avg, 
             :rating_weighted,
             :rating_count, 
             :rating_updated_at,
             :promo,
             :customs_duty

  attribute :promo do |product, params|
    # Get pre-fetched promos if available, otherwise fetch active now
    promos = params[:active_promos] || PromoCode.active_now.to_a
    
    # Check pre-calculated applicability if available
    applicability = params[:promo_applicability] || {}
    applicable = if applicability.key?(product.sku)
                   applicability[product.sku]
                 else
                   # Fallback (may trigger DB hits)
                   cat_ids = [product.category_id] + product.category_products.map(&:category_id)
                   promos.select { |p| p.applies_to_sku?(product.sku, cat_ids) }
                 end
    
    # Pick the one with the highest discount
    best = applicable.max_by do |p| 
      p.discount_type == 'percent' ? p.discount_value : (p.discount_value / 4.0) 
    end

    if best
      {
        code: best.code,
        discount_value: best.discount_value.to_f,
        discount_type: best.discount_type
      }
    end
  end

  attribute :customs_duty do |product, params|
    # Price and weight are required for calculation
    if product.price.to_f > 0 && product.weight.to_f > 0
      # Try to get rates from params, otherwise fetch from DB/API
      rates = params[:rates] || {
        eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
        pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      }
      
      if rates[:eur] && rates[:pln]
        price_eur = (product.price.to_f * rates[:pln] / rates[:eur]).round(2)
        calculation = CustomsDutyService.calculate(price_eur, product.weight.to_f, rates[:eur])
        {
          total_byn: calculation[:total_byn],
          duty_byn: calculation[:duty_byn],
          fee_byn: calculation[:fee_byn],
          details: calculation[:details]
        }
      end
    end
  end

  attribute :price_pln do |product|
    product.price.to_f
  end

  attribute :price_byn do |product, params|
    # Упрощенный расчет для листинга: только цена товара с наценкой
    # Без учета индивидуальной доставки и весовой логистики (они в корзине)
    pln_price = product.price.to_f
    if pln_price > 0
      markup_k = PriceCalculationService.compute_k(pln_price)
      
      rates = params[:rates] || {}
      rate = rates[:pln] || ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
      
      settings = params[:calculator_settings] || {}
      buffer = settings['exchange_rate_buffer'] || PriceCalculationService.exchange_rate_buffer
      
      (pln_price * (1 + markup_k) * rate * buffer).round(2)
    else
      0
    end
  end

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    product.slug
  end
  
  attribute :variants do |product|
    ProductSerializer.normalize_variants(product.variants)
  end
  
  attribute :local_images do |product|
    images = product.local_images
    if images.is_a?(String)
      begin
        JSON.parse(images)
      rescue JSON::ParserError
        [images]
      end
    else
      Array(images)
    end
  end

  attribute :related_products do |product|
    raw = product.related_products
    items = if raw.is_a?(Array)
              raw
            elsif raw.is_a?(String) && raw.present?
              begin
                JSON.parse(raw)
              rescue JSON::ParserError
                []
              end
            else
              []
            end

    items.filter_map do |item|
      if item.is_a?(Hash)
        (item["sku"] || item[:sku] || item["item_no"] || item[:item_no]).presence
      else
        item.to_s.presence
      end
    end
  end
  
  belongs_to :category, serializer: CategorySerializer, if: Proc.new { |record| record.category.present? }
  has_many :categories, serializer: CategorySerializer
  
  attribute :delivery_days do |product, params|
    # Приоритет: Категория -> Глобальная настройка -> 30 (fallback)
    global_default = params[:calculator_settings]&.dig('default_delivery_days') || CalculatorSetting.get('default_delivery_days') || 30
    product.primary_category&.delivery_days.presence || global_default
  end

  attribute :display_blocks do |product, params|
    category = product.category
    settings = params[:calculator_settings] || {}
    
    # Глобальные настройки
    global_delivery = (settings['show_delivery_block_global'] || CalculatorSetting.get('show_delivery_block_global')) != 0
    global_reviews = (settings['show_reviews_block_global'] || CalculatorSetting.get('show_reviews_block_global')) != 0
    global_tips = (settings['show_tips_block_global'] || CalculatorSetting.get('show_tips_block_global')) != 0

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

  attribute :seo do |product, params|
    SeoHelper.meta_for(product, params[:city])
  end

  attribute :tips, if: Proc.new { |_product, params| params && params[:detail] } do |product|
    articles = ContentArticle.visible.tips_ideas.relevant_for_product(product).limit(5)
    ContentArticleTeaserSerializer.new(articles).serializable_hash[:data].map { |a| a[:attributes] }
  end

  attribute :full_attributes_ru do |product|
    full = product.full_attributes_ru || {}
    {
      "description" => full["description"],
      "size" => full["size"],
      "materials" => full["materials"],
      "instructions" => full["instructions"]
    }.compact
  end

  def self.normalize_documents(documents)
    Array(documents).filter_map do |doc|
      if doc.is_a?(Hash)
        url = doc["url"] || doc[:url]
        local_url = doc["local_url"] || doc[:local_url]
        title = doc["title"] || doc[:title]
        next if url.blank? && local_url.blank?
        final_url = local_url.presence || url
        { title: title, url: final_url }.compact
      else
        url = doc.to_s
        next if url.blank?

        { url: url }
      end
    end
  end

  def self.normalize_variants(raw)
    entries = case raw
              when Array then raw
              when Hash then [raw]
              when String
                begin
                  JSON.parse(raw)
                rescue JSON::ParserError
                  []
                end
              else
                []
              end

    entries.map do |entry|
      if entry.is_a?(Hash)
        {
          sku: extract_variant_sku(entry),
          name: extract_variant_name(entry),
          price: extract_variant_price(entry),
          images: extract_variant_images(entry),
          quantity: extract_variant_quantity(entry)
        }
      else
        {
          name: entry.to_s.presence,
          price: nil,
          images: [],
          quantity: nil
        }
      end
    end
  end

  def self.extract_variant_name(entry)
    entry["name_ru"] || entry[:name_ru] ||
      entry["name"] || entry[:name] ||
      entry["typeName"] || entry[:typeName] ||
      entry["validDesignText"] || entry[:validDesignText]
  end

  def self.extract_variant_sku(entry)
    entry["id"] || entry[:id] ||
      entry["itemNoGlobal"] || entry[:itemNoGlobal] ||
      entry["itemNo"] || entry[:itemNo]
  end

  def self.extract_variant_price(entry)
    price = entry.dig("salesPrice", "numeral") ||
            entry.dig(:salesPrice, :numeral) ||
            entry.dig("price", "numeral") ||
            entry.dig(:price, :numeral) ||
            entry["price"] ||
            entry[:price]

    if price.is_a?(String)
      price = price.gsub(/[^\d,.]/, "").gsub(",", ".").to_f
    end

    price
  end

  def self.extract_variant_images(entry)
    images = entry["local_images"] || entry[:local_images]
    normalize_variant_images(images)
  end

  def self.extract_variant_quantity(entry)
    quantity = entry["quantity"] || entry[:quantity]
    if quantity.is_a?(Hash)
      quantity = quantity["quantity"] || quantity[:quantity]
    end
    quantity
  end

  def self.normalize_variant_images(value)
    return [] if value.blank?

    if value.is_a?(String)
      begin
        value = JSON.parse(value)
      rescue JSON::ParserError
        return value.present? ? [value] : []
      end
    end

    Array(value).filter_map do |item|
      if item.is_a?(Hash)
        item["url"] || item[:url] ||
          item["imageUrl"] || item[:imageUrl]
      else
        item.to_s.presence
      end
    end
  end
end

