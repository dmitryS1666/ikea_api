class CheckoutService
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

    # Создание заказа
    order = nil
    
    Order.transaction do
      order = Order.new(
        user: user,
        status: :created,
        total_amount: pricing[:totals][:total_byn], # Финальная сумма к оплате
        delivery_price: pricing[:totals][:delivery_total_byn], # Сохраняем стоимость доставки
        discount_amount: pricing[:totals][:discount_total_byn],
        promo_code: cart.promo_code,
        full_name: params[:full_name],
        phone: params[:phone],
        delivery_type: params[:delivery_type],
        payment_method: params[:payment_method],
        address_json: (params[:address] || {}).merge(
          pickup_point_id: params[:pickup_point_id],
          services: params[:services],
          passport_provided: passport_input.present?,
          weight_kg: pricing[:totals][:total_weight_kg],
          pln_total: pricing[:totals][:total_pln]
        )
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
      OrderNotificationService.call(order)
      CrmIntegrationService.sync_order(order)
      { success: true, order: order }
    else
      { error: order&.errors&.full_messages&.join(', ') || 'Ошибка создания заказа' }
    end
  end
end
