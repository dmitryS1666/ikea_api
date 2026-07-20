class OrderNotificationService
  def self.call(order, status_changed: false)
    if status_changed
      handle_status_change(order)
    else
      # После оформления: сразу «в обработке», через ~20с «ожидает оплаты»
      # (если к этому моменту ещё не оплачен). Статусные письма — в той же FIFO.
      TransactionalEmailService.send_order_emails(%i[order_created order_awaiting_payment], order)
      enqueue_admin_order_created_email(order)
      send_telegram_manager_notification(order)
    end
  end

  private

  def self.handle_status_change(order)
    template_key = EmailTemplates::Renderer.template_for_order(order)

    if template_key
      TransactionalEmailService.send_order_email(template_key, order)
    end

    tg_statuses = %w[confirmed paid purchased received_poland export_eu arrived_pvz handed_to_courier handed_to_courier_ikeya]
    if tg_statuses.include?(order.status)
      send_telegram_status_notification(order)
    end
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

  def self.build_admin_order_created_html(order)
    items_html = order.order_items.map { |item| "<li>#{item.product_sku} x#{item.quantity}</li>" }.join
    admin_order_url = "#{ENV.fetch('API_BASE_URL', '').to_s.sub(%r{/\z}, '')}/admin/orders/#{order.id}"

    services_html = admin_services_html_block(order)

    <<~HTML
      <h2>Новый заказ №#{order.id}</h2>
      <p>Имя клиента: #{order.full_name || "—"}</p>
      <p>Телефон: #{order.phone || "—"}</p>
      <p>Email: #{order.user&.email || "—"}</p>
      <p>Сумма: #{order.total_amount || "—"} BYN</p>
      #{services_html}
      <p>Список товаров:</p>
      <ul>#{items_html.presence || "<li>Товары отсутствуют</li>"}</ul>
      <p>Ссылка в админку: #{admin_order_url}</p>
    HTML
  end

  def self.build_admin_order_created_text(order)
    items = order.order_items.map { |item| "- #{item.product_sku} x#{item.quantity}" }
    admin_order_url = "#{ENV.fetch('API_BASE_URL', '').to_s.sub(%r{/\z}, '')}/admin/orders/#{order.id}"

    lines = [
      "Новый заказ №#{order.id}",
      "Имя клиента: #{order.full_name || '—'}",
      "Телефон: #{order.phone || '—'}",
      "Email: #{order.user&.email || '—'}",
      "Сумма: #{order.total_amount || '—'} BYN"
    ]
    lines.concat(admin_services_text_lines(order))
    lines.concat(
      [
        "Список товаров:",
        (items.presence || ["- Товары отсутствуют"]).join("\n"),
        "Ссылка в админку: #{admin_order_url}"
      ]
    )
    lines.join("\n")
  end

  def self.send_telegram_manager_notification(order)
    message = "🆕 <b>Новый заказ №#{order.id}</b>\n\n"
    message += "👤 Клиент: #{order.full_name}\n"
    message += "📞 Телефон: #{order.phone}\n"
    message += "💰 Сумма: #{order.total_amount} BYN\n"
    message += "🚚 Доставка: #{order.delivery_type}\n"
    message += "💳 Оплата: #{order.payment_method}\n"

    if (service_labels = OrderServicesFormatter.labels(order.address_json["services"])).present?
      message += "\n🛠 <b>Доп. услуги:</b>\n"
      service_labels.each { |label| message += "- <b>#{label}</b>\n" }
    end

    message += "\n<i>Менеджеру необходимо связаться с клиентом в течение 30 минут.</i>"

    TelegramService.send_message(message)
  end

  def self.admin_services_html_block(order)
    labels = OrderServicesFormatter.labels(order.address_json["services"])
    return "" if labels.blank?

    items = labels.map { |label| "<li><strong>#{label}</strong></li>" }.join
    "<p><strong>Доп. услуги:</strong></p><ul>#{items}</ul>\n"
  end

  def self.admin_services_text_lines(order)
    labels = OrderServicesFormatter.labels(order.address_json["services"])
    return [] if labels.blank?

    ["Доп. услуги:", *labels.map { |label| "- #{label}" }]
  end

  def self.send_telegram_status_notification(order)
    status_text = I18n.t("activerecord.attributes.order.statuses.#{order.status}")
    message = "📦 <b>Заказ №#{order.id}</b>\n"
    message += "Статус изменен на: <b>#{status_text}</b>"

    if order.user&.respond_to?(:telegram_chat_id) && order.user.telegram_chat_id.present?
      TelegramService.send_message(message)
    end
  end
end
