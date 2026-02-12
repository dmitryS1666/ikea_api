class OrderMailer < ApplicationMailer
  def order_created(order)
    @order = order
    @user = order.user
    
    mail(to: @user.email, subject: "Заказ №#{@order.id} принят в работу") if @user.email.present?
  end
end
