class ProductTeaserSerializer
  include FastJsonapi::ObjectSerializer

  attributes :sku,
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

  attribute :name_ru do |product|
    product.name.to_s.presence
  end

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
    safe_weight = safe_product_weight_kg(product)

    if product.price.to_f > 0 && safe_weight.present?
      rates = params[:rates] || {
        eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
        pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      }
      
      if rates[:eur] && rates[:pln]
        price_eur = (product.price.to_f * rates[:pln] / rates[:eur]).round(2)
        calculation = CustomsDutyService.calculate(price_eur, safe_weight, rates[:eur])
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
    pln_price = product.price.to_f
  
    if pln_price > 0
      rates = params[:rates] || {}
      pln_rate = rates[:pln] || ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
  
      settings = params[:calculator_settings] || {}
      buffer = settings['exchange_rate_buffer'] || PriceCalculationService.exchange_rate_buffer
  
      price = PriceCalculationService.product_price_byn(
        pln_price,
        weight_kg: product.packaging_weight_kg.to_f,
        delivery_pln: product.delivery_cost.to_f,
        pln_rate: pln_rate,
        buffer: buffer
      )
  
      ActionController::Base.helpers.number_with_delimiter(price, delimiter: ' ')
    else
      "0"
    end
  end

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    Products::PublicProductUrl.public_slug(product)
  end

  # Публичный артикул для URL: без listing-префикса `s`.
  # Сам `sku` не меняем, чтобы не ломать корзину/избранное/заказы и связи вариантов.
  attribute :url_sku do |product|
    Products::PublicProductUrl.sku_core(product.sku)
  end

  attribute :product_path do |product|
    Products::PublicProductUrl.path(product)
  end

  attribute :local_images do |product|
    ProductLocalImages.expand_paths(product.local_images)
  end

  attribute :variants do |product|
    product.normalized_variants_for_api
  end

  def self.safe_product_weight_kg(product)
    Products::WeightExtractor.packaging_weight_kg_for_product(product)
  end
end
