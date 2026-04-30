class OrderNotificationService
  def self.call(order, status_changed: false)
    if status_changed
      handle_status_change(order)
    else
      enqueue_sendpulse_order_created_emails(order)
      send_telegram_manager_notification(order)
    end
  end

  private

  def self.handle_status_change(order)
    # Согласно таблице БП:
    # Email notify: Новый, Подтвержден, Оплачен, Выкуплен, Получен на склад, Подготовка к отправке, Экспорт из ЕС, Передано в доставку, Прибыло в отделение, Выдано курьеру, Доставлено
    # TG/Viber: Подтвержден, Оплачен, Выкуплен, Получен на склад, Экспорт из ЕС, Прибыло в отделение, Выдано курьеру

    email_statuses = %w[created confirmed paid purchased received_poland preparing_for_shipment export_eu shipped arrived_pvz handed_to_courier completed]
    tg_statuses = %w[confirmed paid purchased received_poland export_eu arrived_pvz handed_to_courier]

    if email_statuses.include?(order.status)
      OrderMailer.status_updated(order).deliver_later if order.user&.email.present?
    end

    if tg_statuses.include?(order.status)
      send_telegram_status_notification(order)
    end
  end

  def self.enqueue_sendpulse_order_created_emails(order)
    enqueue_client_order_created_email(order)
    enqueue_admin_order_created_email(order)
  end

  def self.enqueue_client_order_created_email(order)
    customer_email = order.user&.email
    return if customer_email.blank?

    SendpulseEmailJob.perform_later(
      to_email: customer_email,
      to_name: order.full_name.presence || order.user&.full_name,
      subject: "Ваш заказ принят",
      html: build_customer_order_created_html(order),
      text: build_customer_order_created_text(order)
    )
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Failed to enqueue client order created email for order=#{order.id}: #{e.class} #{e.message}")
  end

  def self.enqueue_admin_order_created_email(order)
    admin_email = ENV["SENDPULSE_ADMIN_NOTIFY_EMAIL"]
    return if admin_email.blank?

    SendpulseEmailJob.perform_later(
      to_email: admin_email,
      subject: "Новый заказ №#{order.id}",
      html: build_admin_order_created_html(order),
      text: build_admin_order_created_text(order)
    )
  rescue StandardError => e
    Rails.logger.error("[SendPulse] Failed to enqueue admin order created email for order=#{order.id}: #{e.class} #{e.message}")
  end

  def self.build_customer_order_created_html(order)
    <<~HTML
      <h2>Ваш заказ принят</h2>
      <p>Номер заказа: #{order.id}</p>
      <p>Имя клиента: #{order.full_name.presence || order.user&.full_name || "—"}</p>
      <p>Сумма заказа: #{order.total_amount || "—"} BYN</p>
      <p>Статус заказа: #{order.status}</p>
      <p>Контакты магазина: #{ENV.fetch("STORE_CONTACT_INFO", "Свяжитесь с нами через поддержку IKEA.")}</p>
    HTML
  end

  def self.build_customer_order_created_text(order)
    [
      "Ваш заказ принят",
      "Номер заказа: #{order.id}",
      "Имя клиента: #{order.full_name.presence || order.user&.full_name || '—'}",
      "Сумма заказа: #{order.total_amount || '—'} BYN",
      "Статус заказа: #{order.status}",
      "Контакты магазина: #{ENV.fetch('STORE_CONTACT_INFO', 'Свяжитесь с нами через поддержку IKEA.')}"
    ].join("\n")
  end

  def self.build_admin_order_created_html(order)
    items_html = order.order_items.map { |item| "<li>#{item.product_sku} x#{item.quantity}</li>" }.join
    admin_order_url = "#{ENV.fetch('API_BASE_URL', '').to_s.sub(%r{/\z}, '')}/admin/orders/#{order.id}"

    <<~HTML
      <h2>Новый заказ №#{order.id}</h2>
      <p>Имя клиента: #{order.full_name || "—"}</p>
      <p>Телефон: #{order.phone || "—"}</p>
      <p>Email: #{order.user&.email || "—"}</p>
      <p>Сумма: #{order.total_amount || "—"} BYN</p>
      <p>Список товаров:</p>
      <ul>#{items_html.presence || "<li>Товары отсутствуют</li>"}</ul>
      <p>Ссылка в админку: #{admin_order_url}</p>
    HTML
  end

  def self.build_admin_order_created_text(order)
    items = order.order_items.map { |item| "- #{item.product_sku} x#{item.quantity}" }
    admin_order_url = "#{ENV.fetch('API_BASE_URL', '').to_s.sub(%r{/\z}, '')}/admin/orders/#{order.id}"

    [
      "Новый заказ №#{order.id}",
      "Имя клиента: #{order.full_name || '—'}",
      "Телефон: #{order.phone || '—'}",
      "Email: #{order.user&.email || '—'}",
      "Сумма: #{order.total_amount || '—'} BYN",
      "Список товаров:",
      (items.presence || ["- Товары отсутствуют"]).join("\n"),
      "Ссылка в админку: #{admin_order_url}"
    ].join("\n")
  end

  def self.send_telegram_manager_notification(order)
    message = "🆕 <b>Новый заказ №#{order.id}</b>\n\n"
    message += "👤 Клиент: #{order.full_name}\n"
    message += "📞 Телефон: #{order.phone}\n"
    message += "💰 Сумма: #{order.total_amount} BYN\n"
    message += "🚚 Доставка: #{order.delivery_type}\n"
    message += "💳 Оплата: #{order.payment_method}\n"
    
    if order.address_json['services'].present?
      message += "\n🛠 <b>Доп. услуги:</b>\n"
      order.address_json['services'].each { |s| message += "- #{s}\n" }
    end

    message += "\n<i>Менеджеру необходимо связаться с клиентом в течение 30 минут.</i>"
    
    TelegramService.send_message(message)
  end

  def self.send_telegram_status_notification(order)
    status_text = I18n.t("activerecord.attributes.order.statuses.#{order.status}")
    message = "📦 <b>Заказ №#{order.id}</b>\n"
    message += "Статус изменен на: <b>#{status_text}</b>"
    
    # Здесь логика отправки клиенту в ТГ/Viber если он подписан
    # Пока используем общий сервис
    if order.user&.respond_to?(:telegram_chat_id) && order.user.telegram_chat_id.present?
      TelegramService.send_message(message)
    end
  end
end
