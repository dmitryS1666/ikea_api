# frozen_string_literal: true

namespace :sendpulse do
  desc "Реальный smoke-тест всех шаблонов SendPulse (по умолчанию отправка на dsuschinsky0590@yandex.ru)"
  task :real_smoke, [:target_email] => :environment do |_t, args|
    target_email = args[:target_email].to_s.strip.presence || ENV["TARGET_EMAIL"].to_s.strip.presence || "dsuschinsky0590@yandex.ru"
    keep_data = ActiveModel::Type::Boolean.new.cast(ENV.fetch("KEEP_DATA", "true"))

    required_env = %w[SENDPULSE_API_KEY SENDPULSE_FROM_EMAIL]
    missing_env = required_env.select { |key| ENV[key].to_s.strip.blank? }
    if missing_env.any?
      abort("Не заданы ENV: #{missing_env.join(', ')}. Smoke-тест остановлен.")
    end

    puts "== SendPulse real smoke test =="
    puts "TARGET_EMAIL=#{target_email}"
    puts "KEEP_DATA=#{keep_data}"

    singleton = class << SendpulseEmailJob; self; end
    original_perform_later = singleton.instance_method(:perform_later)
    singleton.define_method(:perform_later) do |**payload|
      perform_now(**payload)
    end

    created_records = {}
    unique_phone = lambda do
      loop do
        suffix = SecureRandom.random_number(10_000_000).to_s.rjust(7, "0")
        candidate = "37529#{suffix}"
        break candidate unless User.exists?(phone: candidate)
      end
    end

    save_with_details = lambda do |record, label|
      return record if record.save

      raise ActiveRecord::RecordInvalid.new(record), "#{label}: #{record.errors.full_messages.join(', ')}"
    end

    begin
      user = User.find_or_initialize_by(email: target_email)
      if user.new_record?
        stamp = Time.current.to_i
        generated_password = SecureRandom.hex(16)
        user.assign_attributes(
          username: "sendpulse_smoke_#{stamp}",
          phone: unique_phone.call,
          password: generated_password,
          password_confirmation: generated_password,
          role: "user",
          is_active: true,
          personal_data_consent: true
        )
        save_with_details.call(user, "Ошибка создания пользователя")
        puts "✅ Пользователь создан: id=#{user.id}"
      else
        puts "✅ Пользователь найден: id=#{user.id}"
      end
      created_records[:user] = user

      products = Product.where.not(price: nil).where("price > 0").limit(3).to_a
      abort("Не найдено минимум 2 товаров с ценой > 0 для smoke-теста.") if products.size < 2

      cart = user.cart || user.build_cart(guest_token: SecureRandom.hex(24))
      cart.save! if cart.new_record?
      cart.cart_items.delete_all

      products.each_with_index do |product, idx|
        cart.cart_items.create!(
          product_sku: product.sku,
          quantity: idx + 1
        )
      end
      puts "✅ Корзина подготовлена: cart_id=#{cart.id}, items=#{cart.cart_items.count}"

      total_amount = cart.cart_items.includes(:product).sum { |item| item.line_total_byn.to_f }.round(2)
      address_payload = { city: "Minsk", services: [] }

      draft_order = Order.create!(
        user: user,
        checkout_draft: true,
        status: :created,
        full_name: user.full_name,
        phone: user.phone,
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        payment_method: "cash",
        address_json: address_payload,
        total_amount: total_amount
      )
      cart.cart_items.each do |item|
        draft_order.order_items.create!(
          product_sku: item.product_sku,
          quantity: item.quantity,
          price: item.product&.price || 0
        )
      end
      draft_order.update_column(:created_at, 4.hours.ago)
      created_records[:draft_order] = draft_order
      puts "✅ Черновик заказа создан: order_id=#{draft_order.id}"

      puts "➡️ Отправка шаблона order_created"
      OrderNotificationService.notify_draft_created(draft_order)

      puts "➡️ Отправка шаблона abandoned_cart"
      SendAbandonedCartEmailsJob.perform_now

      order = Order.create!(
        user: user,
        checkout_draft: false,
        status: :created,
        full_name: user.full_name,
        phone: user.phone,
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        payment_method: "cash",
        address_json: address_payload,
        total_amount: total_amount
      )
      cart.cart_items.each do |item|
        order.order_items.create!(
          product_sku: item.product_sku,
          quantity: item.quantity,
          price: item.product&.price || 0
        )
      end
      created_records[:order] = order
      puts "✅ Боевой заказ создан: order_id=#{order.id}"

      puts "➡️ Отправка шаблона order_awaiting_payment"
      OrderNotificationService.call(order, status_changed: false)

      status_flow = %w[paid received_poland shipped cancelled]
      status_flow.each do |status|
        puts "➡️ Смена статуса: #{order.status} -> #{status}"
        order.update!(status: status)
      end

      puts "➡️ Отправка шаблона welcome"
      TransactionalEmailService.send_welcome(user)

      puts "➡️ Отправка шаблона email_changed"
      TransactionalEmailService.send_email_changed(user, target_email)

      puts "✅ Smoke-тест завершен."
      puts "Проверьте почтовый ящик #{target_email}."
    ensure
      singleton.define_method(:perform_later, original_perform_later)

      unless keep_data
        created_records[:draft_order]&.destroy!
        created_records[:order]&.destroy!
        puts "🗑️ Тестовые заказы удалены (KEEP_DATA=false)."
      end
    end
  end
end
