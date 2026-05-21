class CartSummaryService
  def self.call(cart:, items: nil)
    effective =
      if items.present?
        built = CartSelectionService.build_subset_cart(cart: cart, selections: items)
        return built if built[:error]

        built[:cart]
      else
        cart
      end

    return { error: 'Корзина пуста' } if effective.cart_items.blank?

    pricing = CartPricingService.call(cart: effective)
    totals = pricing[:totals]
    delivery_options = DeliveryOptionsService.call(effective)
    rules = CartRulesService.call(subtotal_new_byn: totals[:subtotal_new_byn])

    {
      items_count: effective.cart_items.sum(&:quantity),
      subtotal_new_byn: format_byn(totals[:subtotal_new_byn]),
      discount_total_byn: format_byn(totals[:discount_total_byn]),
      customs_total_byn: format_byn(totals[:customs_total_byn]),
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn]),
      total_weight_kg: totals[:total_weight_kg].to_f,
      total_byn: format_byn(totals[:total_byn]),
      delivery: format_delivery(totals, delivery_options),
      meta: {
        min_order_amount_byn: format_byn(rules[:rules][:min_order_amount_byn]),
        checkout_allowed: rules[:flags][:checkout_allowed],
        min_order_error: rules[:flags][:checkout_allowed] ? nil : "Оформление доступно от #{rules[:rules][:min_order_amount_byn]} руб."
      }
    }
  end

  def self.format_delivery(totals, delivery_options)
    methods = Array(delivery_options[:methods]).map do |method|
      {
        code: method[:code],
        available: method[:available],
        reason: method[:reason]
      }
    end

    {
      available_methods: methods,
      europost_eligible: delivery_options.dig(:cart_vgh, :eligible_for_europost) == true,
      ineligible_reason: delivery_options.dig(:cart_vgh, :ineligible_reason),
      total_weight_kg: totals[:total_weight_kg].to_f,
      delivery_to_belarus_byn: format_byn(totals[:delivery_to_belarus_byn]),
      delivery_total_byn: format_byn(totals[:delivery_total_byn])
    }
  end

  def self.format_byn(value)
    format('%.2f', value.to_f)
  end
end
