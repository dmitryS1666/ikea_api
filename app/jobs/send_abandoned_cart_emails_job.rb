class SendAbandonedCartEmailsJob < ApplicationJob
  queue_as :default

  def perform
    delay_hours = ENV.fetch("ABANDONED_CART_EMAIL_DELAY_HOURS", "2").to_i
    cutoff = delay_hours.hours.ago

    Order
      .where(checkout_draft: true, status: Order.statuses[:created])
      .where(abandoned_cart_email_sent_at: nil)
      .where("created_at <= ?", cutoff)
      .includes(:user, order_items: :product)
      .find_each do |order|
        next if order.user&.email.blank?

        TransactionalEmailService.send_order_email(:abandoned_cart, order)
        order.update_column(:abandoned_cart_email_sent_at, Time.current)
      end
  end
end
