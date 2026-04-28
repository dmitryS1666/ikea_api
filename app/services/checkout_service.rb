class CheckoutService
  SUPPORTED_DELIVERY_TYPES = [
    DeliveryTypeNormalizer::EUROPOST_PICKUP,
    DeliveryTypeNormalizer::COURIER,
    DeliveryTypeNormalizer::IKEYA_DELIVERY
  ].freeze

  def self.call(user:, params:)
    cart = user.cart
    return { error: 'Корзина не найдена' } unless cart
    return { error: 'Корзина пуста' } if cart.cart_items.blank?

    # Passport validation skipped for brevity, same as original
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
      # Skip verification if a1_verification_id matches and user is already verified with that ID
      # or if the user is verified and didn't change anything (but passport_changed was true due to formatting)
      skip_verification = user.passport_verified? && 
                          params[:a1_verification_id].present? && 
                          params[:a1_verification_id].to_s == user.a1_verification_id.to_s

      if skip_verification
        verification_id = user.a1_verification_id
      else
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
    end

    # Пересчет и проверка с использованием динамических правил
    pricing = CartPricingService.call(cart: cart)
    
    unless pricing[:meta][:can_checkout]
      return { error: pricing[:meta][:min_order_error] }
    end

    # Проверка наличия (заглушка)
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

    delivery_options = DeliveryOptionsService.call(cart)
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

    delivery_context = resolve_delivery_context(user: user, params: params, delivery_type: normalized_delivery_type)
    return delivery_context if delivery_context[:error]

    eta = DeliveryEtaService.call(
      order_date: Date.current,
      with_storage: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
    )
    prices = delivery_prices_for(weight_kg: pricing[:totals][:total_weight_kg], delivery_type: normalized_delivery_type)
    total_amount = pricing[:totals][:total_byn].to_f - pricing[:totals][:delivery_total_byn].to_f + prices[:total_delivery_price_byn]

    delivery_snapshot = {
      type: normalized_delivery_type,
      provider: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP ? "europost" : nil,
      delivery_date: eta[:delivery_date],
      storage_until: eta[:storage_until],
      prices: {
        delivery_price_byn: format_price(prices[:delivery_price_byn]),
        delivery_to_belarus_price_byn: format_price(prices[:delivery_to_belarus_price_byn]),
        total_delivery_price_byn: format_price(prices[:total_delivery_price_byn])
      },
      pickup_point: delivery_context[:pickup_point_snapshot],
      address: delivery_context[:address_snapshot]
    }

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

    # Создание заказа
    order = nil
    
    Order.transaction do
      order = Order.new(
        user: user,
        status: :created,
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
        # Перенос товаров
        cart.cart_items.each do |cart_item|
          price_snapshot = pricing[:items].find { |i| i[:sku] == cart_item.product_sku }
          
          OrderItem.create!(
            order: order,
            product_sku: cart_item.product_sku,
            quantity: cart_item.quantity,
            price: price_snapshot[:unit_price_byn] # Фиксируем финальную цену (включая наценку K)
          )
        end

        cart.cart_items.destroy_all
        cart.update!(promo_code: nil)

        if passport_changed
          UserPassportService.write!(user: user, passport_hash: passport_input)
          user.update!(passport_verified_at: Time.current, a1_verification_id: verification_id)
        end
      else
        raise ActiveRecord::Rollback
      end
    end

    if order&.persisted?
      WebpayPaymentLinkService.issue_link!(order)
      OrderNotificationService.call(order)
      { success: true, order: order }
    else
      { error: order&.errors&.full_messages&.join(', ') || 'Ошибка создания заказа' }
    end
  end

  def self.resolve_delivery_context(user:, params:, delivery_type:)
    case delivery_type
    when DeliveryTypeNormalizer::EUROPOST_PICKUP
      pickup_payload = params[:pickup_point].respond_to?(:to_unsafe_h) ? params[:pickup_point].to_unsafe_h : params[:pickup_point]
      pickup_point = params[:pickup_point_id].present? ? PickupPoint.find_by(id: params[:pickup_point_id], provider: "europost", active: true) : nil

      pickup_snapshot = if pickup_point
        {
          id: pickup_point.id,
          external_id: pickup_point.id.to_s,
          address: pickup_point.address,
          working_hours: pickup_point.working_hours
        }
      elsif pickup_payload.present?
        {
          id: pickup_payload["id"] || pickup_payload[:id],
          external_id: pickup_payload["external_id"] || pickup_payload[:external_id],
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
          has_elevator: delivery_address.has_elevator,
          intercom: delivery_address.intercom,
          is_private_house: delivery_address.is_private_house,
          lat: delivery_address.lat,
          lng: delivery_address.lng,
          comment: delivery_address.comment
        }.compact
      elsif address_payload.present?
        address_payload.to_h
      end

      return { error: "Для #{delivery_type} требуется delivery_address_id или address payload" } if address_snapshot.blank?
      { pickup_point_snapshot: nil, address_snapshot: address_snapshot }
    else
      { error: "Неподдерживаемый тип доставки" }
    end
  end

  def self.delivery_prices_for(weight_kg:, delivery_type:)
    pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
    buffer = PriceCalculationService.exchange_rate_buffer
    rate = pln_rate * buffer

    poland_delivery_byn = (PolandDeliveryService.calculate(weight_kg) * rate).round(2)
    belarus_delivery_byn = (BelarusDeliveryService.calculate(weight_kg) * rate).round(2)

    delivery_price_byn =
      if delivery_type == DeliveryTypeNormalizer::IKEYA_DELIVERY
        0.0
      else
        poland_delivery_byn
      end

    {
      delivery_price_byn: delivery_price_byn.round(2),
      delivery_to_belarus_price_byn: belarus_delivery_byn.round(2),
      total_delivery_price_byn: (delivery_price_byn + belarus_delivery_byn).round(2)
    }
  end

  def self.format_price(value)
    format("%.2f", value.to_f)
  end
end
