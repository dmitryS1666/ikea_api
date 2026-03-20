class CartAutoPromoService
  # Auto-apply promo code when cart contains an item that has a promo.
  # Requirement: if user selects a product with a promo and later opens cart,
  # the promo should be already applied.
  #
  # We intentionally keep this conservative:
  # - do nothing if promo already set
  # - apply the first active promo that has at least one matching cart item
  # - if multiple promos match, prefer the one that gives the biggest discount
  def self.call(cart:)
    return cart if cart.promo_code_id.present?

    skus = cart.cart_items.pluck(:product_sku)
    return cart if skus.empty?

    promo_ids = PromoCodeProduct.where(product_sku: skus).distinct.pluck(:promo_code_id)
    return cart if promo_ids.empty?

    promos = PromoCode.where(id: promo_ids).select(&:active_now?)
    return cart if promos.empty?

    best = choose_best_promo(promos, skus)
    return cart unless best

    cart.update!(promo_code: best)
    cart
  end

  def self.choose_best_promo(promos, skus)
    # Pre-calculate applicability for all items
    products = Product.includes(:category_products).where(sku: skus).to_a
    promo_applicability = CartPricingService.get_promo_applicability(products, promos)
    prices = products.index_by(&:sku)

    promos.max_by do |promo|
      skus.sum do |sku|
        is_applicable = promo_applicability[sku]&.include?(promo)
        next 0 unless is_applicable
        
        price = prices[sku]&.price.to_f
        next 0 if price <= 0
        CartPricingService.calculate_unit_discount_pln(promo, price)
      end
    end
  end
  private_class_method :choose_best_promo
end
