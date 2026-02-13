class OrderMailer < ApplicationMailer
  def order_created(order)
    @order = order
    @user = order.user
    
    mail(to: @user.email, subject: "Заказ №#{@order.id} принят в работу") if @user.email.present?
  end

  def status_updated(order)
    @order = order
    @user = order.user
    @status_text = I18n.t("activerecord.attributes.order.status.#{@order.status}")
    
    mail(to: @user.email, subject: "Статус заказа №#{@order.id} изменен: #{@status_text}") if @user.email.present?
  end
end
