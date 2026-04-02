class ProductTeaserSerializer
  include FastJsonapi::ObjectSerializer

  attributes :sku,
             :name_ru,
             :small_desc_name,
             :slug,
             :price, 
             :price_pln,
             :price_byn,
             :quantity, 
             :is_bestseller, 
             :is_new,
             :is_recommended,
             :is_popular, 
             :category_id,
             :rating_avg,
             :rating_weighted,
             :rating_count,
             :rating_updated_at,
             :local_images,
             :variants,
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
    # Only calculate if we have price and weight
    if product.price.to_f > 0 && product.weight.to_f > 0
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

  attribute :delivery_days do |product, params|
    # Приоритет: Категория -> Глобальная настройка -> 30 (fallback)
    global_default = params[:calculator_settings]&.dig('default_delivery_days') || CalculatorSetting.get('default_delivery_days') || 30
    product.primary_category&.delivery_days.presence || global_default
  end

  attribute :price_byn do |product, params|
    eur_price = product.price.to_f
  
    if eur_price > 0
      markup_k = PriceCalculationService.compute_k(eur_price)
  
      rates = params[:rates] || {}
      rate = rates[:eur] || ExchangeRate.fetch_or_create('EUR')&.rate_per_unit || 0
  
      settings = params[:calculator_settings] || {}
      buffer = settings['exchange_rate_buffer'] || PriceCalculationService.exchange_rate_buffer
  
      price = (eur_price * (1 + markup_k) * rate * buffer).round(2)
  
      ActionController::Base.helpers.number_with_delimiter(price, delimiter: ' ')
    else
      "0"
    end
  end

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    product.slug
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

  attribute :variants do |product, params|
    raw_variants = Array(product.variants)
    
    variant_skus = raw_variants.filter_map do |variant|
      case variant
      when Hash
        variant["sku"] || variant[:sku] || variant["value"] || variant[:value]
      when String, Integer
        variant.to_s
      end
    end.map(&:to_s).uniq
    
    variants_map =
      params&.dig(:variant_products_map) ||
      Product.where(sku: variant_skus).index_by { |p| p.sku.to_s }
    
    raw_variants.map do |variant|
      sku =
        case variant
        when Hash
          variant["sku"] || variant[:sku] || variant["value"] || variant[:value]
        when String, Integer
          variant.to_s
        end
    
      sku = sku.to_s
      variant_product = variants_map[sku]
    
      local_images =
        begin
          raw = variant_product&.local_images
          raw = JSON.parse(raw) if raw.is_a?(String)
          Array(raw).compact
        rescue JSON::ParserError
          []
        end
    
      {
        sku: sku.presence,
        name_ru: variant_product&.name_ru,
        small_desc_name: variant_product&.small_desc_name,
        price: variant_product&.price&.to_s,
        images: local_images,
        quantity: variant_product&.quantity
      }
    end.compact
  end
end
