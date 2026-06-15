class ProductTeaserSerializer
  include FastJsonapi::ObjectSerializer

  attributes :small_desc_name,
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

  attribute :name do |product|
    product.name.to_s.presence
  end

  attribute :name_ru do |product|
    product.name_ru.to_s.presence || product.name.to_s.presence
  end

  attribute :breadcrumbs, if: proc { |_product, params| params[:search_context] } do |product|
    Seo::BreadcrumbsBuilder.for_product(product)
  end

  attribute :images, if: proc { |_product, params| params[:search_context] } do |product, params|
    site_url = params[:site_url].to_s.chomp("/")
    paths = ProductLocalImages.preview_paths(product.local_images)
    paths.map { |path| absolute_image_url(path, site_url) }
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
  
      price = PriceCalculationService.product_storefront_price_byn(
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
    product.slug
  end

  attribute :local_images do |product|
    ProductLocalImages.preview_paths(product.local_images)
  end

  attribute :variants do |product|
    product.normalized_variants_for_api
  end

  def self.safe_product_weight_kg(product)
    Products::WeightExtractor.packaging_weight_kg_for_product(product)
  end

  def self.public_sku(sku)
    sku.to_s.sub(/\As(?=\d+\z)/i, "")
  end

  def self.absolute_image_url(path, site_url)
    path = path.to_s.strip
    return path if path.blank?
    return path if path.match?(%r{\Ahttps?://}i)

    base = site_url.to_s.chomp("/")
    return path if base.blank?

    path.start_with?("/") ? "#{base}#{path}" : "#{base}/#{path}"
  end

  attribute :sku do |product|
    public_sku(product.sku)
  end
end
