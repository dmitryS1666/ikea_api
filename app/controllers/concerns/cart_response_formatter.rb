module CartResponseFormatter
  private

  def cart_response_payload(cart, token, pricing_cart: cart)
    # `cart` is the real cart and is used for rendering item rows.
    # `pricing_cart` may be a virtual subset built from selected items; it is
    # used only for totals/rules/delivery so unchecked items do not affect the
    # visible order summary.
    pricing = CartPricingService.call(cart: pricing_cart)
    line_pricing = pricing_cart.equal?(cart) ? pricing : CartPricingService.call(cart: cart)
    totals = CartDisplayTotalsService.for_summary(pricing[:totals])
    rules_data = CartRulesService.call(subtotal_new_byn: totals[:subtotal_new_byn])
    pricing_map = line_pricing[:items].index_by { |entry| entry[:sku] }
    cart_items = cart.cart_items.includes(:product)
    delivery_options = DeliveryOptionsService.call(pricing_cart)

    {
      cart: {
        token: token || cart.guest_token,
        expires_at: cart.expires_at.iso8601,
        items_count: cart_items.sum(:quantity),
        items: build_items(cart_items, pricing_map),
        totals: format_totals(totals),
        delivery: format_cart_delivery(totals, delivery_options),
        rules: format_rules(rules_data[:rules]),
        flags: format_flags(rules_data[:flags]),
        recommendations: build_recommendations(cart_items),
        passport_data: cart.user&.passport_data,
        passport_verified: cart.user&.passport_verified? || false,
        a1_verification_id: cart.user&.a1_verification_id
      }
    }
  end

  def build_items(cart_items, pricing_map)
    cart_items.map do |item|
      product = item.product
      available = product.present? && (product.quantity.nil? || product.quantity.positive?)
      issue_reason = issue_reason_for(product, available)
      similar = available || product.nil? ? [] : build_similar_products(product)
      pricing_line = pricing_map[item.product_sku] || {}

      {
        sku: public_sku(item.product_sku),
        quantity: item.quantity,
        available: available,
        issue_reason: issue_reason,
        product: product_payload(product),
        pricing: pricing_payload(pricing_line),
        similar_products: similar
      }
    end
  end

  def pricing_payload(pricing_line)
    quantity = [pricing_line[:quantity].to_i, 1].max
    unit_before = pricing_line[:unit_price_byn_before_discount]
    unit_after = pricing_line[:unit_price_byn]
    line_before = (unit_before.to_f * quantity).round(2)

    {
      unit_price_old_byn: format_byn(unit_before),
      unit_price_new_byn: format_byn(unit_after),
      unit_discount_byn: format_byn(pricing_line[:unit_discount_byn]),
      line_total_old_byn: format_byn(line_before),
      line_total_new_byn: format_byn(pricing_line[:line_total_byn]),
      line_discount_byn: format_byn(pricing_line[:line_discount_byn]),
      customs_duty_byn: format_byn(pricing_line[:customs_duty_byn]),
      customs_fee_byn: format_byn(pricing_line[:customs_fee_byn]),
      customs_total_byn: format_byn(pricing_line[:customs_total_byn]),
      promo_applied: pricing_line[:promo_applied] || false,
      promo_code: pricing_line[:promo_code]
    }
  end

  def product_payload(product)
    return nil unless product

    {
      sku: public_sku(product.sku),
      name: product.name,
      price_byn: format_byn(
        PriceCalculationService.product_storefront_price_byn(
          product.price,
          weight_kg: product.packaging_weight_kg.to_f,
          delivery_pln: product.delivery_cost.to_f
        )
      ),
      quantity: product.quantity,
      category_id: product.category_id,
      collection: product.collection,
      images: {
        local_images: ProductLocalImages.expand_paths(product.local_images || []),
        images: product.images || []
      }
    }
  end

  def build_similar_products(product)
    SimilarProductsService.for(product: product, limit: 8).map do |similar|
      {
        sku: public_sku(similar.sku),
        name: similar.name,
        price_byn: format_byn(
          PriceCalculationService.product_storefront_price_byn(
            similar.price,
            weight_kg: similar.packaging_weight_kg.to_f,
            delivery_pln: similar.delivery_cost.to_f
          )
        ),
        quantity: similar.quantity,
        category_id: similar.category_id,
        collection: similar.collection,
        images: {
          local_images: ProductLocalImages.expand_paths(similar.local_images || []),
          images: similar.images || []
        }
      }
    end
  end

  def build_recommendations(cart_items)
    exclude_skus = cart_items.map(&:product_sku)
  
    ProductRecommendationsResolver.call(
      placement: :cart,
      limit: 8,
      exclude_skus: exclude_skus
    ).map do |product|
      recommendation_payload(product)
    end
  end
  
  def recommendation_payload(product)
    {
      sku: public_sku(product.sku),
      name: product.name,
      price_byn: format_byn(
        PriceCalculationService.product_storefront_price_byn(
          product.price,
          weight_kg: product.packaging_weight_kg.to_f,
          delivery_pln: product.delivery_cost.to_f
        )
      ),
      quantity: product.quantity,
      category_id: product.category_id,
      collection: product.collection,
      images: {
        local_images: ProductLocalImages.expand_paths(product.local_images || []),
        images: product.images || []
      }
    }
  end

  def issue_reason_for(product, available)
    return 'not_found' if product.nil?
    return 'unavailable' unless available

    nil
  end

  def format_totals(totals)
    subtotal_new = totals[:subtotal_new_byn].to_f
    discount = totals[:discount_total_byn].to_f
    subtotal_old = totals[:subtotal_old_byn]
    subtotal_old = (subtotal_new + discount).round(2) if subtotal_old.nil?

    {
      items_total_byn: format_byn(totals[:items_total_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn]),
      delivery_poland_byn: format_byn(totals[:delivery_poland_byn]),
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      total_byn: format_byn(totals[:total_byn]),
      final_total_byn: format_byn(totals[:final_total_byn] || totals[:total_byn]),
      subtotal_old_byn: format_byn(subtotal_old),
      subtotal_new_byn: format_byn(totals[:subtotal_new_byn]),
      discount_total_byn: format_byn(totals[:discount_total_byn]),
      customs_duty_byn: format_byn(totals[:customs_duty_byn]),
      customs_fee_byn: format_byn(totals[:customs_fee_byn]),
      customs_total_byn: format_byn(totals[:customs_total_byn]),
      total_weight_kg: totals[:total_weight_kg]
    }
  end

  # Оценка доставки для корзины: внутренние тарифы, без API Европочты (см. POST /delivery/calculate на checkout).
  def format_cart_delivery(totals, delivery_options)
    methods = Array(delivery_options[:methods]).map do |method|
      {
        code: method[:code],
        available: method[:available],
        reason: method[:reason]
      }
    end

    {
      pricing_source: "internal_cart",
      total_weight_kg: totals[:total_weight_kg].to_f,
      delivery_poland_byn: format_byn(totals[:delivery_poland_byn]),
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn]),
      available_methods: methods,
      europost_eligible: delivery_options.dig(:cart_vgh, :eligible_for_europost) == true,
      ineligible_reason: delivery_options.dig(:cart_vgh, :ineligible_reason)
    }
  end

  def format_rules(rules)
    {
      min_order_amount_byn: format_byn(rules[:min_order_amount_byn]),
      free_delivery_threshold_byn: format_byn(rules[:free_delivery_threshold_byn])
    }
  end

  def format_flags(flags)
    {
      checkout_allowed: flags[:checkout_allowed],
      min_order_missing_byn: format_byn(flags[:min_order_missing_byn]),
      free_delivery_eligible: flags[:free_delivery_eligible],
      free_delivery_missing_byn: format_byn(flags[:free_delivery_missing_byn])
    }
  end

  def public_sku(sku)
    Product.public_sku(sku)
  end

  def format_byn(value)
    sprintf('%.2f', value.to_f)
  end
end
