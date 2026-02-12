class OrderNotificationService
  def self.call(order)
    # 1. Email уведомление клиенту
    OrderMailer.order_created(order).deliver_later if order.user.email.present?

    # 2. Telegram уведомление менеджеру
    send_telegram_manager_notification(order)

    # 3. Уведомление в ЛК (через статус заказа, который уже в БД)
    # Если бы была система внутренних нотификаций, добавили бы сюда
  end

  private

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
end
