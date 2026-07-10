class CheckoutService
  SUPPORTED_DELIVERY_TYPES = [
    DeliveryTypeNormalizer::EUROPOST_PICKUP,
    DeliveryTypeNormalizer::COURIER,
    DeliveryTypeNormalizer::IKEYA_DELIVERY
  ].freeze

  def self.call(user:, params:)
    if truthy_draft?(params)
      create_draft(user: user, params: params)
    else
      complete_checkout(user: user, params: params)
    end
  end

  def self.update_draft(user:, order_id:, params:)
    order = user.orders.find_by(id: order_id, checkout_draft: true)
    return { error: 'Черновик заказа не найден', code: 'draft_not_found' } unless order

    items_check = CartSelectionService.validate_against_order!(order: order, params: params)
    return items_check if items_check[:error]

    pricing = CartPricingService.call_from_order(order: order.reload)
    unless pricing[:meta][:can_checkout]
      return { error: pricing[:meta][:min_order_error] }
    end

    cart = CartPricingService.order_as_cart(order)

    normalized_delivery_type = nil
    if params[:delivery_type].present?
      normalized_delivery_type = DeliveryTypeNormalizer.normalize(params[:delivery_type])
      unless SUPPORTED_DELIVERY_TYPES.include?(normalized_delivery_type)
        return { error: "Неподдерживаемый тип доставки", delivery_type: params[:delivery_type], normalized_delivery_type: normalized_delivery_type }
      end

      delivery_options = DeliveryOptionsService.call(cart)
      selected_method = delivery_options[:methods].find { |m| m[:code] == normalized_delivery_type }
      if selected_method.nil? || !selected_method[:available]
        return {
          error: "Выбранный тип доставки недоступен для заказа",
          delivery_type: params[:delivery_type],
          normalized_delivery_type: normalized_delivery_type,
          reason: selected_method&.dig(:reason),
          available_methods: delivery_options[:methods]
        }
      end

      delivery_context = resolve_delivery_context(
        user: user,
        params: params,
        delivery_type: normalized_delivery_type,
        delivery_options: delivery_options,
        require_address: false
      )
      return delivery_context if delivery_context[:error]

      eta = DeliveryEtaService.call(
        order_date: Date.current,
        with_storage: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
      )
      prices = checkout_delivery_prices(
        pricing: pricing,
        raw_prices: delivery_prices_for(
          weight_kg: pricing[:totals][:total_weight_kg],
          delivery_type: normalized_delivery_type,
          parcels: delivery_options[:parcels],
          pickup_point_id: params[:pickup_point_id],
          address: delivery_context[:address_snapshot]
        )
      )
      total_amount = checkout_total_amount(pricing: pricing, prices: prices)

      delivery_snapshot = build_delivery_snapshot(
        normalized_delivery_type: normalized_delivery_type,
        eta: eta,
        prices: prices,
        pickup_point_snapshot: delivery_context[:pickup_point_snapshot],
        address_snapshot: delivery_context[:address_snapshot]
      )

      passport_input = params[:passport].is_a?(Hash) ? params[:passport] : (params[:passport].to_unsafe_h rescue nil)

      address_snapshot = (params[:address] || {}).merge(
        pickup_point_id: params[:pickup_point_id].present? ? params[:pickup_point_id].to_i : nil,
        services: params[:services],
        passport_provided: passport_input.present?,
        weight_kg: pricing[:totals][:total_weight_kg],
        pln_total: pricing[:totals][:total_pln],
        delivery_eta: {
          delivery_date: eta[:delivery_date],
          storage_until: eta[:storage_until]
        },
        delivery: delivery_snapshot,
        checkout_draft: true
      )

      order.assign_attributes(
        total_amount: total_amount.round(2),
        delivery_price: prices[:total_delivery_price_byn],
        discount_amount: pricing[:totals][:discount_total_byn],
        delivery_type: normalized_delivery_type,
        weight: pricing[:totals][:total_weight_kg],
        address_json: address_snapshot,
        full_name: params[:full_name].presence || order.full_name,
        phone: params[:phone].presence || order.phone,
        payment_method: params[:payment_method].presence || order.payment_method
      )
    else
      patch_optional_fields(order, params)
    end

    if order.save
      order.reload
      pricing_response = draft_pricing_response(order, pricing: pricing)
      { success: true, order: order, pricing: pricing_response }
    else
      { error: order.errors.full_messages.join(', ') }
    end
  end

  def self.finalize(user:, order_id:, params:)
    order = user.orders.find_by(id: order_id, checkout_draft: true)
    return { error: 'Черновик заказа не найден', code: 'draft_not_found' } unless order

    items_check = CartSelectionService.validate_against_order!(order: order, params: params)
    return items_check if items_check[:error]

    merged = merge_params_for_finalize(order, params)
    merged_params = ActiveSupport::HashWithIndifferentAccess.new(merged)

    consent_check = ConsentService.validate_checkout_consents!(merged_params, user: user)
    return consent_check if consent_check

    passport_result = verify_passport!(user: user, params: merged_params)
    return passport_result if passport_result[:error]

    verification_id = passport_result[:verification_id]
    passport_changed = passport_result[:passport_changed]
    passport_input = passport_result[:passport_input]

    pricing = CartPricingService.call_from_order(order: order.reload)
    unless pricing[:meta][:can_checkout]
      return { error: pricing[:meta][:min_order_error] }
    end

    pricing[:items].each do |item|
      product = Product.find_by(sku: item[:sku])
      if product && product.quantity.to_i <= 0
        return { error: "Товара #{product.name} нет в наличии" }
      end
    end

    cart = CartPricingService.order_as_cart(order)

    normalized_delivery_type = DeliveryTypeNormalizer.normalize(merged[:delivery_type])
    unless SUPPORTED_DELIVERY_TYPES.include?(normalized_delivery_type)
      return { error: "Неподдерживаемый тип доставки", delivery_type: merged[:delivery_type], normalized_delivery_type: normalized_delivery_type }
    end

    delivery_options = DeliveryOptionsService.call(cart)
    selected_method = delivery_options[:methods].find { |m| m[:code] == normalized_delivery_type }
    if selected_method.nil? || !selected_method[:available]
      return {
        error: "Выбранный тип доставки недоступен для текущего заказа",
        delivery_type: merged[:delivery_type],
        normalized_delivery_type: normalized_delivery_type,
        reason: selected_method&.dig(:reason),
        available_methods: delivery_options[:methods]
      }
    end

    delivery_context = resolve_delivery_context(
      user: user,
      params: merged_params,
      delivery_type: normalized_delivery_type,
      delivery_options: delivery_options
    )
    return delivery_context if delivery_context[:error]

    eta = DeliveryEtaService.call(
      order_date: Date.current,
      with_storage: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
    )
    prices = checkout_delivery_prices(
      pricing: pricing,
      raw_prices: delivery_prices_for(
        weight_kg: pricing[:totals][:total_weight_kg],
        delivery_type: normalized_delivery_type,
        parcels: delivery_options[:parcels],
        pickup_point_id: merged[:pickup_point_id],
        address: delivery_context[:address_snapshot]
      )
    )
    total_amount = checkout_total_amount(pricing: pricing, prices: prices)

    delivery_snapshot = build_delivery_snapshot(
      normalized_delivery_type: normalized_delivery_type,
      eta: eta,
      prices: prices,
      pickup_point_snapshot: delivery_context[:pickup_point_snapshot],
      address_snapshot: delivery_context[:address_snapshot]
    )

    raw_addr = merged[:address]
    addr_src =
      case raw_addr
      when Hash then raw_addr
      else
        raw_addr.respond_to?(:to_unsafe_h) ? raw_addr.to_unsafe_h : {}
      end
    address_snapshot = addr_src.merge(
      pickup_point_id: merged[:pickup_point_id].present? ? merged[:pickup_point_id].to_i : nil,
      services: merged[:services],
      passport_provided: passport_input.present?,
      weight_kg: pricing[:totals][:total_weight_kg],
      pln_total: pricing[:totals][:total_pln],
      delivery_eta: {
        delivery_date: eta[:delivery_date],
        storage_until: eta[:storage_until]
      },
      delivery: delivery_snapshot
    )

    Order.transaction do
      order.assign_attributes(
        status: :processing,
        checkout_draft: false,
        total_amount: total_amount.round(2),
        delivery_price: prices[:total_delivery_price_byn],
        discount_amount: pricing[:totals][:discount_total_byn],
        full_name: merged[:full_name],
        phone: merged[:phone],
        delivery_type: normalized_delivery_type,
        weight: pricing[:totals][:total_weight_kg],
        payment_method: merged[:payment_method],
        address_json: address_snapshot
      )

      unless order.save
        raise ActiveRecord::Rollback
      end

      if passport_changed && passport_input
        UserPassportService.write!(user: user, passport_hash: passport_input)
        user.update!(passport_verified_at: Time.current, a1_verification_id: verification_id)
      end
    end

    if order.reload.persisted? && !order.checkout_draft
      ConsentService.record_checkout_consents!(user: user, order: order, params: merged_params)

      user_cart = user.cart
      if user_cart
        consume_selections = CartSelectionService.selections_from_order(order)
        clear_cart_after_checkout!(cart: user_cart, selections: consume_selections)
      end

      WebpayPaymentLinkService.issue_link!(order)
      OrderNotificationService.call(order)
      { success: true, order: order }
    else
      { error: order.errors.full_messages.join(', ') || 'Не удалось завершить оформление' }
    end
  end

  def self.cancel_draft(user:, order_id:)
    order = user.orders.find_by(id: order_id, checkout_draft: true)
    return { error: 'Черновик заказа не найден', code: 'draft_not_found' } unless order

    order.destroy!
    { success: true }
  end

  def self.complete_checkout(user:, params:)
    if user.orders.exists?(checkout_draft: true)
      draft = user.orders.find_by(checkout_draft: true)
      return {
        error: 'Сначала завершите или отмените оформление заказа в корзине',
        code: 'checkout_draft_exists',
        draft_order_id: draft&.id
      }
    end

    cart_result = resolve_base_cart(user: user, params: params)
    return cart_result if cart_result[:error]

    cart = cart_result[:cart]
    cart_context = resolve_checkout_cart(cart: cart, params: params)
    return cart_context if cart_context[:error]

    checkout_cart = cart_context[:cart]
    selections = cart_context[:selections]

    consent_check = ConsentService.validate_checkout_consents!(params, user: user)
    return consent_check if consent_check

    passport_input = params[:passport].is_a?(Hash) ? params[:passport] : (params[:passport].to_unsafe_h rescue nil)
    if passport_input.present?
      number = passport_input['passport_number'] || passport_input[:passport_number] || passport_input['number'] || passport_input[:number]
      series = passport_input['series'] || passport_input[:series]

      full_number = if series.present? && number.present? && !number.to_s.match?(/[a-zA-Z\u0400-\u04FF]/)
                      "#{series}#{number}"
                    else
                      number
                    end

      if full_number.present? && !PassportNumberValidator.valid?(full_number)
        return { error: 'Номер паспорта должен быть в формате: 2 буквы и 7 цифр (например, MP1234567)', code: 'invalid_passport_number' }
      end
    end
    current_passport = user.passport_data
    passport_changed = passport_input.present? && !UserPassportService.same?(passport_input, current_passport)

    verification_id = nil
    if passport_changed
      last4 = params[:a1_verification_last4] || params[:verification_code]
      verification = VerificationCode.valid_code(user.phone.to_s.gsub(/\D/, ''), last4).first

      if verification.nil?
        return {
          error: 'Требуется подтверждение паспорта через звонок',
          code: 'passport_verification_required',
          passport_data: user.passport_data,
          a1_verification_id: user.a1_verification_id
        }
      end
      verification_id = verification.id
      verification.destroy!
    end

    pricing = CartPricingService.call(cart: checkout_cart)

    unless pricing[:meta][:can_checkout]
      return { error: pricing[:meta][:min_order_error] }
    end

    pricing[:items].each do |item|
      product = Product.find_by(sku: item[:sku])
      if product && product.quantity.to_i <= 0
        return { error: "Товара #{product.name} нет в наличии" }
      end
    end

    normalized_delivery_type = DeliveryTypeNormalizer.normalize(params[:delivery_type])
    unless SUPPORTED_DELIVERY_TYPES.include?(normalized_delivery_type)
      return { error: "Неподдерживаемый тип доставки", delivery_type: params[:delivery_type], normalized_delivery_type: normalized_delivery_type }
    end

    delivery_options = DeliveryOptionsService.call(checkout_cart)
    selected_method = delivery_options[:methods].find { |method| method[:code] == normalized_delivery_type }
    if selected_method.nil? || !selected_method[:available]
      return {
        error: "Выбранный тип доставки недоступен для текущей корзины",
        delivery_type: params[:delivery_type],
        normalized_delivery_type: normalized_delivery_type,
        reason: selected_method&.dig(:reason),
        available_methods: delivery_options[:methods]
      }
    end

    delivery_context = resolve_delivery_context(
      user: user,
      params: params,
      delivery_type: normalized_delivery_type,
      delivery_options: delivery_options
    )
    return delivery_context if delivery_context[:error]

    eta = DeliveryEtaService.call(
      order_date: Date.current,
      with_storage: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
    )
    prices = checkout_delivery_prices(
      pricing: pricing,
      raw_prices: delivery_prices_for(
        weight_kg: pricing[:totals][:total_weight_kg],
        delivery_type: normalized_delivery_type,
        parcels: delivery_options[:parcels],
        pickup_point_id: params[:pickup_point_id],
        address: delivery_context[:address_snapshot]
      )
    )
    total_amount = checkout_total_amount(pricing: pricing, prices: prices)

    delivery_snapshot = build_delivery_snapshot(
      normalized_delivery_type: normalized_delivery_type,
      eta: eta,
      prices: prices,
      pickup_point_snapshot: delivery_context[:pickup_point_snapshot],
      address_snapshot: delivery_context[:address_snapshot]
    )

    address_snapshot = (params[:address] || {}).merge(
      pickup_point_id: params[:pickup_point_id].present? ? params[:pickup_point_id].to_i : nil,
      services: params[:services],
      passport_provided: passport_input.present?,
      weight_kg: pricing[:totals][:total_weight_kg],
      pln_total: pricing[:totals][:total_pln],
      delivery_eta: {
        delivery_date: eta[:delivery_date],
        storage_until: eta[:storage_until]
      },
      delivery: delivery_snapshot
    )

    order = nil

    Order.transaction do
      order = Order.new(
        user: user,
        status: :processing,
        checkout_draft: false,
        total_amount: total_amount.round(2),
        delivery_price: prices[:total_delivery_price_byn],
        discount_amount: pricing[:totals][:discount_total_byn],
        promo_code: cart.promo_code,
        full_name: params[:full_name],
        phone: params[:phone],
        delivery_type: normalized_delivery_type,
        weight: pricing[:totals][:total_weight_kg],
        payment_method: params[:payment_method],
        address_json: address_snapshot
      )

      if order.save
        checkout_cart.cart_items.each do |cart_item|
          price_snapshot = pricing[:items].find { |i| i[:sku] == cart_item.product_sku }

          OrderItem.create!(
            order: order,
            product_sku: cart_item.product_sku,
            quantity: cart_item.quantity,
            price: price_snapshot[:unit_price_byn_checkout]
          )
        end

        clear_cart_after_checkout!(cart: cart, selections: selections)

        if passport_changed
          UserPassportService.write!(user: user, passport_hash: passport_input)
          user.update!(passport_verified_at: Time.current, a1_verification_id: verification_id)
        end
      else
        raise ActiveRecord::Rollback
      end
    end

    if order&.persisted?
      ConsentService.record_checkout_consents!(user: user, order: order, params: params)

      WebpayPaymentLinkService.issue_link!(order)
      OrderNotificationService.call(order)
      { success: true, order: order }
    else
      { error: order&.errors&.full_messages&.join(', ') || 'Ошибка создания заказа' }
    end
  end

  def self.create_draft(user:, params:)
    cart_result = resolve_base_cart(user: user, params: params)
    return cart_result if cart_result[:error]

    cart = cart_result[:cart]
    cart_context = resolve_checkout_cart(cart: cart, params: params)
    return cart_context if cart_context[:error]

    checkout_cart = cart_context[:cart]
    selections = cart_context[:selections]
    requested_selections = CartSelectionService.normalize_selections(cart: checkout_cart, selections: selections)

    existing = user.orders.find_by(checkout_draft: true)
    if existing
      return refresh_or_reuse_draft(
        user: user,
        order: existing,
        cart: cart,
        checkout_cart: checkout_cart,
        requested_selections: requested_selections,
        params: params
      )
    end

    stock_check = validate_stock_for_pricing_items(checkout_cart, params)
    return stock_check if stock_check[:error]

    pricing = CartPricingService.call(cart: checkout_cart)
    unless pricing[:meta][:can_checkout]
      return { error: pricing[:meta][:min_order_error] }
    end

    order = build_draft_order(
      user: user,
      cart: cart,
      checkout_cart: checkout_cart,
      pricing: pricing,
      params: params
    )

    pricing_for_response = nil
    if order&.persisted?
      if order.delivery_type.present?
        update_result = update_draft(user: user, order_id: order.id, params: params)
        return update_result unless update_result[:success]

        order = update_result[:order]
        pricing_for_response = update_result[:pricing]
      end

      OrderNotificationService.notify_draft_created(order.reload)

      {
        success: true,
        order: order,
        delivery_options: draft_delivery_options_for(order),
        pricing: pricing_for_response || draft_pricing_response(order, pricing: pricing)
      }
    else
      { error: order&.errors&.full_messages&.join(', ') || 'Ошибка создания черновика заказа' }
    end
  end

  def self.draft_pricing_response(order, pricing: nil)
    pricing_payload = pricing || CartPricingService.call_from_order(order: order)
    summary = CheckoutPricingPresenter.for_order(order, pricing: pricing_payload)
    sync_draft_order_totals!(order, summary)
    summary
  end

  def self.sync_draft_order_totals!(order, summary)
    return unless order.checkout_draft? && order.persisted? && summary.is_a?(Hash)

    totals = summary[:totals] || {}
    total_amount = totals[:total_byn].to_f.round(2)
    delivery_price = totals[:delivery_total_byn].to_f.round(2)
    return if order.total_amount.to_f == total_amount && order.delivery_price.to_f == delivery_price

    order.update_columns(total_amount: total_amount, delivery_price: delivery_price)
  end

  def self.resolve_delivery_context(user:, params:, delivery_type:, delivery_options: nil, require_address: true)
    case delivery_type
    when DeliveryTypeNormalizer::EUROPOST_PICKUP
      pickup_payload = params[:pickup_point].respond_to?(:to_unsafe_h) ? params[:pickup_point].to_unsafe_h : params[:pickup_point]
      europost_office = params[:pickup_point_id].present? ? find_europost_office(params[:pickup_point_id]) : nil

      if delivery_options.present?
        cart_vgh = delivery_options[:cart_vgh] || {}
        unless cart_vgh[:eligible_for_europost]
          return { error: "Европочта недоступна для текущих ВГХ корзины" }
        end
      end

      pickup_snapshot = if europost_office
        if delivery_options.present?
          parcels = Array(delivery_options[:parcels])
          unless DeliveryOptionsService.europost_office_supports_parcels?(office: europost_office, parcels: parcels)
            return { error: "Выбранный ПВЗ Европочты недоступен для текущих ВГХ корзины" }
          end
        end

        europost_pickup_snapshot(europost_office)
      elsif pickup_payload.present?
        {
          id: pickup_payload["id"] || pickup_payload[:id],
          external_id: pickup_payload["external_id"] || pickup_payload[:external_id],
          name: pickup_payload["name"] || pickup_payload[:name],
          city: pickup_payload["city"] || pickup_payload[:city],
          address: pickup_payload["address"] || pickup_payload[:address],
          working_hours: pickup_payload["working_hours"] || pickup_payload[:working_hours]
        }.compact
      end

      return { error: "Для europost_pickup требуется pickup_point_id или payload ПВЗ" } if pickup_snapshot.blank?
      { pickup_point_snapshot: pickup_snapshot, address_snapshot: nil }
    when DeliveryTypeNormalizer::COURIER, DeliveryTypeNormalizer::IKEYA_DELIVERY
      delivery_address = params[:delivery_address_id].present? ? user.user_delivery_addresses.alive.find_by(id: params[:delivery_address_id]) : nil
      address_payload = params[:address].respond_to?(:to_unsafe_h) ? params[:address].to_unsafe_h : params[:address]

      address_snapshot = if delivery_address
        {
          id: delivery_address.id,
          city: delivery_address.city,
          street: delivery_address.street,
          house: delivery_address.house,
          building: delivery_address.building,
          apartment: delivery_address.apartment,
          entrance: delivery_address.entrance,
          floor: delivery_address.floor,
          elevator_type: delivery_address.elevator_type,
          intercom: delivery_address.intercom,
          is_private_house: delivery_address.is_private_house,
          lat: delivery_address.lat,
          lng: delivery_address.lng,
          comment: delivery_address.comment
        }.compact
      elsif address_payload.present?
        address_payload.to_h
      end

      if address_snapshot.blank?
        if require_address
          return { error: "Для #{delivery_type} требуется delivery_address_id или address payload" }
        end

        return { pickup_point_snapshot: nil, address_snapshot: nil }
      end

      { pickup_point_snapshot: nil, address_snapshot: address_snapshot }
    else
      { error: "Неподдерживаемый тип доставки" }
    end
  end

  def self.find_europost_office(pickup_point_id)
    external_id = pickup_point_id.to_s
    DeliveryOptionsService.europost_offices.find { |office| office["WarehouseId"].to_s == external_id }
  rescue StandardError => e
    Rails.logger.error("[EUROPOST] checkout office lookup failed #{e.class}: #{e.message}")
    nil
  end

  def self.europost_pickup_snapshot(office)
    external_id = office["WarehouseId"].to_s
    summary = EuropostWorkingHoursFormatter.summary_for_payload(office)
    structured = EuropostWorkingHoursFormatter.structured_for_payload(office)

    {
      id: external_id,
      external_id: external_id,
      name: office["WarehouseName"],
      city: office["Address7Name"],
      address: europost_office_address(office),
      phone: EuropostOfficePhone.for_office(office)
    }.merge(structured).merge(working_hours: summary)
  end

  def self.europost_office_address(office)
    [office["Address5Name"], office["Address4Name"], office["Address3Name"]]
      .map { |value| value.to_s.strip }
      .reject(&:blank?)
      .join(", ")
      .presence
  end

  def self.europost_office_working_hours(office)
    EuropostWorkingHoursFormatter.summary_for_payload(office)
  end

  def self.delivery_prices_for(weight_kg:, delivery_type:, parcels: nil, pickup_point_id: nil, address: nil)
    pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
    buffer = PriceCalculationService.exchange_rate_buffer
    rate = pln_rate * buffer

    fin = DeliveryCalculateFinance.call(
      normalized_delivery_type: delivery_type,
      weight_kg: weight_kg,
      pln_rate_with_buffer: rate,
      parcels: parcels,
      pickup_point_id: pickup_point_id,
      address: address
    )

    {
      delivery_price_byn: fin[:delivery_price_byn].round(2),
      delivery_to_belarus_price_byn: fin[:delivery_to_belarus_price_byn].round(2),
      total_delivery_price_byn: fin[:total_delivery_price_byn].round(2)
    }
  end

  def self.checkout_delivery_prices(pricing:, raw_prices:)
    raw = (raw_prices || {}).with_indifferent_access

    # CartPricingService is the source of truth for the public "delivery to
    # Belarus" amount shown in cart. Checkout must not replace it with the
    # value returned by the selected pickup/courier calculation, otherwise the
    # same order shows different Belarus delivery on cart and checkout screens.
    #
    # The selected delivery calculation contributes only the method component
    # (Europost pickup/courier/IKEYA). The additive checkout contract is:
    #   delivery_to_belarus_price_byn + delivery_price_byn = total_delivery_price_byn
    cart_delivery_to_belarus = cart_delivery_to_belarus_from_pricing(pricing)
    method_delivery = raw[:delivery_price_byn].to_f.round(2)
    normalized_total = (cart_delivery_to_belarus + method_delivery).round(2)

    {
      delivery_price_byn: method_delivery,
      delivery_to_belarus_price_byn: cart_delivery_to_belarus,
      total_delivery_price_byn: normalized_total,
      provider_delivery_price_byn: method_delivery,
      provider_delivery_to_belarus_price_byn: raw[:delivery_to_belarus_price_byn].to_f.round(2),
      provider_total_delivery_price_byn: raw[:total_delivery_price_byn].to_f.round(2)
    }
  end
  private_class_method :checkout_delivery_prices

  def self.checkout_total_amount(pricing:, prices:)
    totals = CartDisplayTotalsService.for_summary(pricing[:totals])
    subtotal = totals[:subtotal_new_byn].to_f
    discount = totals[:discount_total_byn].to_f
    delivery_total = prices[:total_delivery_price_byn].to_f

    [(subtotal - discount + delivery_total), 0.0].max.round(2)
  end
  private_class_method :checkout_total_amount

  def self.cart_delivery_to_belarus_from_pricing(pricing)
    totals = CartDisplayTotalsService.for_summary((pricing || {}).dig(:totals))
    totals[:delivery_to_belarus_byn].to_f.round(2)
  end
  private_class_method :cart_delivery_to_belarus_from_pricing

  def self.format_price(value)
    format("%.2f", value.to_f)
  end

  def self.truthy_draft?(params)
    v = params[:draft]
    v == true || v.to_s == 'true' || v == 1 || v.to_s == '1'
  end

  def self.draft_delivery_options_for(order)
    cart_like = CartPricingService.order_as_cart(order)
    options = DeliveryOptionsService.call(cart_like)
    enrich_delivery_methods_with_prices!(options, order)
  rescue StandardError => e
    Rails.logger.error("CheckoutService: failed to build draft delivery options for order=#{order&.id}: #{e.class} #{e.message}")
    nil
  end

  def self.enrich_delivery_methods_with_prices!(options, order)
    return options unless options.is_a?(Hash)

    weight_kg = options.dig(:cart_vgh, :weight_kg).to_f
    parcels = options[:parcels]
    aj = order.address_json.is_a?(Hash) ? order.address_json.stringify_keys : {}
    pickup_point_id = aj["pickup_point_id"]
    saved_address = order.address_json.dig("delivery", "address")
    cart_pricing = CartPricingService.call_from_order(order: order)

    methods = Array(options[:methods]).map do |method|
      next method unless method[:available]

      address =
        if method[:code] == DeliveryTypeNormalizer::COURIER || method[:code] == DeliveryTypeNormalizer::IKEYA_DELIVERY
          saved_address
        end

      prices = checkout_delivery_prices(
        pricing: cart_pricing,
        raw_prices: delivery_prices_for(
          weight_kg: weight_kg,
          delivery_type: method[:code],
          parcels: parcels,
          pickup_point_id: method[:code] == DeliveryTypeNormalizer::EUROPOST_PICKUP ? pickup_point_id : nil,
          address: address
        )
      )

      method.merge(
        delivery_price_byn: prices[:delivery_price_byn],
        delivery_method_price_byn: prices[:delivery_price_byn],
        delivery_to_belarus_price_byn: prices[:delivery_to_belarus_price_byn],
        total_delivery_price_byn: prices[:total_delivery_price_byn]
      )
    end

    options.merge(methods: methods)
  end
  private_class_method :enrich_delivery_methods_with_prices!

  def self.build_delivery_snapshot(normalized_delivery_type:, eta:, prices:, pickup_point_snapshot:, address_snapshot:)
    {
      type: normalized_delivery_type,
      provider: [DeliveryTypeNormalizer::EUROPOST_PICKUP, DeliveryTypeNormalizer::COURIER].include?(normalized_delivery_type) ? "europost" : nil,
      delivery_date: eta[:delivery_date],
      storage_until: eta[:storage_until],
      prices: {
        delivery_price_byn: format_price(prices[:delivery_price_byn]),
        delivery_to_belarus_price_byn: format_price(prices[:delivery_to_belarus_price_byn]),
        total_delivery_price_byn: format_price(prices[:total_delivery_price_byn]),
        provider_delivery_price_byn: format_price(prices[:provider_delivery_price_byn]),
        provider_delivery_to_belarus_price_byn: format_price(prices[:provider_delivery_to_belarus_price_byn]),
        provider_total_delivery_price_byn: format_price(prices[:provider_total_delivery_price_byn])
      },
      pickup_point: pickup_point_snapshot,
      address: address_snapshot
    }
  end

  def self.patch_optional_fields(order, params)
    order.full_name = params[:full_name].presence || order.full_name
    order.phone = params[:phone].presence || order.phone
    order.payment_method = params[:payment_method].presence || order.payment_method

    if params[:address].present?
      addr = params[:address].respond_to?(:to_unsafe_h) ? params[:address].to_unsafe_h : params[:address]
      base = order.address_json.is_a?(Hash) ? order.address_json.stringify_keys : {}
      order.address_json = base.merge(addr.stringify_keys).merge("checkout_draft" => true)
    end
  end

  def self.pickup_point_id_from_payload(payload)
    return nil if payload.blank?

    data =
      if payload.respond_to?(:to_unsafe_h)
        payload.to_unsafe_h
      elsif payload.is_a?(Hash)
        payload
      end
    return nil unless data.is_a?(Hash)

    data["id"] || data[:id] || data["external_id"] || data[:external_id]
  end
  private_class_method :pickup_point_id_from_payload

  def self.merge_params_for_finalize(order, params)
    p =
      if params.respond_to?(:to_unsafe_h)
        params.to_unsafe_h
      elsif params.is_a?(Hash)
        params
      else
        {}
      end
    h = p.is_a?(Hash) ? p.stringify_keys : {}
    aj = order.address_json.is_a?(Hash) ? order.address_json.stringify_keys : {}
    {
      full_name: h["full_name"].presence || order.full_name,
      phone: h["phone"].presence || order.phone,
      delivery_type: h["delivery_type"].presence || order.delivery_type,
      payment_method: h["payment_method"].presence || order.payment_method,
      pickup_point_id: h["pickup_point_id"].presence || pickup_point_id_from_payload(h["pickup_point"]) || aj["pickup_point_id"],
      delivery_address_id: h["delivery_address_id"].presence,
      a1_verification_id: h["a1_verification_id"],
      a1_verification_last4: h["a1_verification_last4"],
      verification_code: h["verification_code"],
      services: h["services"],
      pickup_point: h["pickup_point"],
      address: h["address"],
      passport: h["passport"],
      personal_data_consent: h["personal_data_consent"],
      offer_agreement_consent: h["offer_agreement_consent"],
      customs_broker_consent: h["customs_broker_consent"]
    }
  end

  def self.draft_initial_delivery_type(params)
    return nil unless params[:delivery_type].present?

    normalized = DeliveryTypeNormalizer.normalize(params[:delivery_type])
    SUPPORTED_DELIVERY_TYPES.include?(normalized) ? normalized : nil
  end

  def self.verify_passport!(user:, params:)
    raw_passport = params[:passport]
    passport_input =
      if raw_passport.is_a?(Hash)
        raw_passport
      elsif raw_passport.respond_to?(:to_unsafe_h)
        raw_passport.to_unsafe_h
      end
    if passport_input.present?
      number = passport_input['passport_number'] || passport_input[:passport_number] || passport_input['number'] || passport_input[:number]
      series = passport_input['series'] || passport_input[:series]

      full_number = if series.present? && number.present? && !number.to_s.match?(/[a-zA-Z\u0400-\u04FF]/)
                      "#{series}#{number}"
                    else
                      number
                    end

      if full_number.present? && !PassportNumberValidator.valid?(full_number)
        return { error: 'Номер паспорта должен быть в формате: 2 буквы и 7 цифр (например, MP1234567)', code: 'invalid_passport_number' }
      end
    end

    current_passport = user.passport_data
    passport_changed = passport_input.present? && !UserPassportService.same?(passport_input, current_passport)

    verification_id = nil
    if passport_changed
      last4 = params[:a1_verification_last4] || params[:verification_code]
      verification = VerificationCode.valid_code(user.phone.to_s.gsub(/\D/, ''), last4).first

      if verification.nil?
        return {
          error: 'Требуется подтверждение паспорта через звонок',
          code: 'passport_verification_required',
          passport_data: user.passport_data,
          a1_verification_id: user.a1_verification_id
        }
      end
      verification_id = verification.id
      verification.destroy!
    end

    { verification_id: verification_id, passport_changed: passport_changed, passport_input: passport_input }
  end

  def self.resolve_base_cart(user:, params:)
    token = params[:cart_token].presence

    cart = if token.present?
             Cart.find_by(guest_token: token)
           else
             user.cart
           end

    return { error: 'Корзина не найдена', code: 'cart_not_found' } unless cart && !cart.expired?
    return { error: 'Корзина пуста', code: 'cart_empty' } if cart.cart_items.blank?

    { cart: cart }
  end

  def self.resolve_checkout_cart(cart:, params:)
    selection = CartSelectionService.apply(cart: cart, params: params)
    return selection if selection[:error]

    effective_cart = selection[:cart]
    return { error: 'Корзина пуста', code: 'cart_empty' } if effective_cart.cart_items.blank?

    { cart: effective_cart, selections: selection[:selections] }
  end

  def self.clear_cart_after_checkout!(cart:, selections:)
    if selections.present?
      CartSelectionService.consume_from_cart!(cart: cart, selections: selections)
      cart.reload
      cart.update!(promo_code: nil) if cart.cart_items.blank?
    else
      cart.cart_items.destroy_all
      cart.update!(promo_code: nil)
    end
  end

  def self.validate_stock_for_pricing_items(checkout_cart, params)
    checkout_cart.cart_items.each do |cart_item|
      product = Product.find_by(sku: cart_item.product_sku)
      if product && product.quantity.to_i <= 0
        return { error: "Товара #{product.name} нет в наличии" }
      end
    end
    { ok: true }
  end

  def self.refresh_or_reuse_draft(user:, order:, cart:, checkout_cart:, requested_selections:, params:)
    selections_changed = !CartSelectionService.selections_equal?(
      requested_selections,
      CartSelectionService.selections_from_order(order)
    )
    pricing_for_response = nil

    if selections_changed
      stock_check = validate_stock_for_pricing_items(checkout_cart, params)
      return stock_check if stock_check[:error]

      pricing = CartPricingService.call(cart: checkout_cart)
      unless pricing[:meta][:can_checkout]
        return { error: pricing[:meta][:min_order_error] }
      end

      refresh_result = refresh_draft_order!(
        order: order,
        cart: cart,
        checkout_cart: checkout_cart,
        pricing: pricing,
        params: params
      )
      return refresh_result unless refresh_result[:success]

      order = refresh_result[:order]
      pricing_for_response = draft_pricing_response(order, pricing: pricing)
    end

    if params[:delivery_type].present?
      update_result = update_draft(user: user, order_id: order.id, params: params)
      return update_result unless update_result[:success]

      order = update_result[:order]
      pricing_for_response = update_result[:pricing]
    end

    {
      success: true,
      order: order,
      delivery_options: draft_delivery_options_for(order),
      pricing: pricing_for_response || draft_pricing_response(order),
      reused: true
    }
  end

  def self.refresh_draft_order!(order:, cart:, checkout_cart:, pricing:, params:)
    display_totals = CartDisplayTotalsService.for_summary(pricing[:totals])
    total_amount = display_totals[:total_byn].to_f
    delivery_price = display_totals[:delivery_to_belarus_byn].to_f

    Order.transaction do
      sync_draft_order_items!(order: order, checkout_cart: checkout_cart, pricing: pricing)

      order.assign_attributes(
        total_amount: total_amount.round(2),
        delivery_price: delivery_price.round(2),
        discount_amount: pricing[:totals][:discount_total_byn],
        promo_code: cart.promo_code,
        weight: pricing[:totals][:total_weight_kg],
        full_name: params[:full_name].presence || order.full_name,
        phone: params[:phone].presence || order.phone,
        payment_method: params[:payment_method].presence || order.payment_method
      )

      unless params[:delivery_type].present?
        order.delivery_type = nil
        reset_draft_delivery_snapshot!(order)
      end

      raise ActiveRecord::Rollback unless order.save
    end

    if order.reload.persisted?
      { success: true, order: order }
    else
      { error: order.errors.full_messages.join(', ') }
    end
  end

  def self.sync_draft_order_items!(order:, checkout_cart:, pricing:)
    order.order_items.destroy_all

    checkout_cart.cart_items.each do |cart_item|
      price_snapshot = pricing[:items].find { |i| i[:sku] == cart_item.product_sku }

      OrderItem.create!(
        order: order,
        product_sku: cart_item.product_sku,
        quantity: cart_item.quantity,
        price: price_snapshot[:unit_price_byn_checkout]
      )
    end
  end

  def self.delivery_snapshot_prices(order)
    delivery = order.address_json.is_a?(Hash) ? order.address_json["delivery"] || order.address_json[:delivery] : nil
    prices = delivery.is_a?(Hash) ? delivery["prices"] || delivery[:prices] : nil
    return nil unless prices.is_a?(Hash)

    {
      delivery_price_byn: prices["delivery_price_byn"] || prices[:delivery_price_byn],
      total_delivery_price_byn: prices["total_delivery_price_byn"] || prices[:total_delivery_price_byn]
    }.compact
  end
  private_class_method :delivery_snapshot_prices

  def self.reset_draft_delivery_snapshot!(order)
    base = order.address_json.is_a?(Hash) ? order.address_json.stringify_keys : {}
    order.address_json = base.except("delivery", "pickup_point_id", "delivery_eta").merge("checkout_draft" => true)
  end

  def self.build_draft_order(user:, cart:, checkout_cart:, pricing:, params:)
    display_totals = CartDisplayTotalsService.for_summary(pricing[:totals])
    total_amount = display_totals[:total_byn].to_f
    delivery_price = display_totals[:delivery_to_belarus_byn].to_f
    passport_input = params[:passport].is_a?(Hash) ? params[:passport] : (params[:passport].to_unsafe_h rescue nil)

    address_snapshot = (params[:address] || {}).merge(
      pickup_point_id: params[:pickup_point_id].present? ? params[:pickup_point_id].to_i : nil,
      services: params[:services],
      passport_provided: passport_input.present?,
      weight_kg: pricing[:totals][:total_weight_kg],
      pln_total: pricing[:totals][:total_pln],
      checkout_draft: true
    )

    order = nil
    Order.transaction do
      order = Order.new(
        user: user,
        status: :created,
        checkout_draft: true,
        total_amount: total_amount.round(2),
        delivery_price: delivery_price.round(2),
        discount_amount: pricing[:totals][:discount_total_byn],
        promo_code: cart.promo_code,
        full_name: params[:full_name],
        phone: params[:phone],
        delivery_type: draft_initial_delivery_type(params),
        weight: pricing[:totals][:total_weight_kg],
        payment_method: params[:payment_method],
        address_json: address_snapshot
      )

      if order.save
        sync_draft_order_items!(order: order, checkout_cart: checkout_cart, pricing: pricing)
      else
        raise ActiveRecord::Rollback
      end
    end

    order&.persisted? ? order : nil
  end

end
