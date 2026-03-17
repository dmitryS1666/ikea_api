class OrderNotificationService
  def self.call(order, status_changed: false)
    if status_changed
      handle_status_change(order)
    else
      # Первичное уведомление при создании заказа
      OrderMailer.order_created(order).deliver_later if order.user.email.present?
      send_telegram_manager_notification(order)
    end
  end

  private

  def self.handle_status_change(order)
    # Согласно таблице БП:
    # Email notify: Новый, Подтвержден, Оплачен, Выкуплен, Получен на склад, Экспорт из ЕС, Передано в доставку, Прибыло в отделение, Выдано курьеру, Доставлено
    # TG/Viber: Подтвержден, Оплачен, Выкуплен, Получен на склад, Экспорт из ЕС, Прибыло в отделение, Выдано курьеру

    email_statuses = %w[created confirmed paid purchased received_poland export_eu shipped arrived_pvz handed_to_courier completed]
    tg_statuses = %w[confirmed paid purchased received_poland export_eu arrived_pvz handed_to_courier]

    if email_statuses.include?(order.status)
      OrderMailer.status_updated(order).deliver_later if order.user&.email.present?
    end

    if tg_statuses.include?(order.status)
      send_telegram_status_notification(order)
    end
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
    TelegramService.send_message(message) if order.user&.telegram_chat_id.present?
  end
end
