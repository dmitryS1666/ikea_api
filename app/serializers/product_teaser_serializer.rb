class ProductTeaserSerializer
  include FastJsonapi::ObjectSerializer

  attributes :sku,
             :name_ru,
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
    # For lists, it's very important to have active_promos pre-fetched in params
    # to avoid DB hits. If not, we fallback to PromoCode.active_now.to_a
    promos = params[:active_promos] || PromoCode.active_now.to_a
    
    # We find which promos apply to this SKU. Note: applies_to_sku? might still
    # trigger category checks, but it's the most reliable way currently.
    applicable = promos.select { |p| p.applies_to_sku?(product.sku) }
    
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

  attribute :price_byn do |product|
    pln_price = product.price.to_f
    if pln_price > 0
      markup_k = PriceCalculationService.compute_k(pln_price)
      rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
      buffer = PriceCalculationService.exchange_rate_buffer
      (pln_price * (1 + markup_k) * rate * buffer).round(2)
    else
      0
    end
  end

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    source = product.name_ru.presence || product.name.presence || product.sku
    SlugifyService.call(source)
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

  attribute :variants do |product|
    ProductSerializer.normalize_variants(product.variants)
  end
end
