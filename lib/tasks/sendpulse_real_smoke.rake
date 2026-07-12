# frozen_string_literal: true

namespace :sendpulse do
  desc "Синхронно отправить все клиентские email-шаблоны SendPulse на явно указанный тестовый адрес"
  task :real_smoke, [:target_email] => :environment do |_task, args|
    target_email = args[:target_email].to_s.strip.presence || ENV["TARGET_EMAIL"].to_s.strip.presence
    abort <<~MSG if target_email.blank?
      Не указан тестовый email.
      Пример:
        SEND_REAL_EMAILS=YES RAILS_ENV=production bundle exec rake 'sendpulse:real_smoke[test@example.com]'
    MSG

    unless target_email.match?(URI::MailTo::EMAIL_REGEXP)
      abort("Некорректный TARGET_EMAIL: #{target_email.inspect}")
    end

    unless ENV["SEND_REAL_EMAILS"] == "YES"
      abort("Для реальной отправки явно задайте SEND_REAL_EMAILS=YES")
    end

    required_env = %w[SENDPULSE_API_KEY SENDPULSE_FROM_EMAIL]
    missing_env = required_env.select { |key| ENV[key].to_s.strip.blank? }
    abort("Не заданы ENV: #{missing_env.join(', ')}") if missing_env.any?

    keep_data = ActiveModel::Type::Boolean.new.cast(ENV.fetch("KEEP_DATA", "false"))
    created_records = []

    unique_phone = lambda do
      loop do
        suffix = SecureRandom.random_number(10_000_000).to_s.rjust(7, "0")
        candidate = "37529#{suffix}"
        break candidate unless User.exists?(phone: candidate)
      end
    end

    deliver = lambda do |template_key, user:, order: nil, verify_email_url: nil|
      html = EmailTemplates::Renderer.render(
        template_key,
        user: user,
        order: order,
        verify_email_url: verify_email_url
      )

      SendpulseEmailJob.perform_now(
        to_email: target_email,
        to_name: user.full_name,
        subject: "[SMOKE] #{EmailTemplates::Renderer.subject_for(template_key)}",
        html: html,
        text: html.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
      )

      puts "✅ #{template_key}"
    end

    build_order = lambda do |user:, products:, checkout_draft:|
      delivery_price = 24.90
      items_total = products.each_with_index.sum do |product, index|
        product.price.to_f * (index + 1)
      end.round(2)

      order = Order.create!(
        user: user,
        checkout_draft: true,
        status: :created,
        full_name: "Тестовый Получатель",
        phone: user.phone,
        delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
        payment_method: "card",
        address_json: {
          "delivery" => {
            "pickup_point" => {
              "name" => "Европочта №123",
              "city" => "Минск",
              "address" => "ул. Тестовая, 10"
            }
          },
          "services" => []
        },
        delivery_price: delivery_price,
        discount_amount: 0,
        total_amount: items_total + delivery_price,
        personal_data_consent: true,
        offer_agreement_consent: true
      )

      products.each_with_index do |product, index|
        order.order_items.create!(
          product_sku: product.sku,
          quantity: index + 1,
          price: product.price
        )
      end

      unless checkout_draft
        order.update_columns(
          checkout_draft: false,
          payment_url: "#{Seo::PublicSiteUrl.resolve}/smoke-payment/#{order.public_uid}",
          updated_at: Time.current
        )
        OrderEmailSnapshotService.capture!(
          order,
          pricing: { totals: { customs_total_byn: 0 } },
          force: true
        )
      end

      order.reload
    end

    begin
      puts "== SendPulse real smoke =="
      puts "Получатель: #{target_email}"
      puts "Отправка выполняется синхронно; Sidekiq для этого теста не требуется."

      user = User.create!(
        username: "sendpulse_smoke_#{Time.current.to_i}_#{SecureRandom.hex(3)}",
        phone: unique_phone.call,
        role: "user",
        is_active: true,
        personal_data_consent: true
      )
      created_records << user

      products = Product.where.not(price: nil).where("price > 0").limit(2).to_a
      abort("Нужно минимум 2 товара с ценой > 0") if products.size < 2

      draft_order = build_order.call(user: user, products: products, checkout_draft: true)
      final_order = build_order.call(user: user, products: products, checkout_draft: false)
      created_records.unshift(draft_order, final_order)

      order_templates = %i[
        order_created
        order_awaiting_payment
        order_placed
        received_poland
        shipped_to_pvz
        order_cancelled
      ]

      order_templates.each do |template_key|
        deliver.call(template_key, user: user, order: final_order)
      end

      deliver.call(:abandoned_cart, user: user, order: draft_order)

      smoke_verify_url = "#{Seo::PublicSiteUrl.resolve}/profile?email_smoke=1"
      deliver.call(:welcome, user: user, verify_email_url: smoke_verify_url)
      deliver.call(:email_changed, user: user, verify_email_url: smoke_verify_url)

      puts
      puts "✅ Отправлено 9 клиентских писем на #{target_email}."
      puts "Письмо администратору SENDPULSE_ADMIN_NOTIFY_EMAIL в этот smoke-тест не входит."
    ensure
      unless keep_data
        created_records.each do |record|
          record.destroy! if record&.persisted?
        rescue StandardError => e
          warn("Не удалось удалить #{record.class} id=#{record.id}: #{e.class} #{e.message}")
        end
        puts "🗑️ Временные пользователь и заказы удалены."
      end
    end
  end
end
