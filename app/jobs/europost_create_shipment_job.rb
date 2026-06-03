# frozen_string_literal: true

class EuropostCreateShipmentJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    order = Order.find_by(id: order_id)
    return unless order

    result = EuropostCreateShipmentService.call(order)
    return if result.success?

    Rails.logger.warn("[EUROPOST] shipment was not created for order=#{order.id}: #{result.status} #{result.error}")
  end
end
