class UpdateOrderTrackingInfoJob < ApplicationJob
  queue_as :default

  def perform(order_id = nil)
    if order_id
      order = Order.find_by(id: order_id)
      return unless order&.track_number.present?
      
      DeliveryTrackingService.call(order)
    else
      # Periodic update for active orders with track numbers
      Order.where.not(track_number: [nil, ""])
           .where.not(status: [:completed, :cancelled])
           .find_each do |order|
        UpdateOrderTrackingInfoJob.perform_later(order.id)
      end
    end
  end
end
