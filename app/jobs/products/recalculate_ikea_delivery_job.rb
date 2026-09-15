# frozen_string_literal: true

class Products::RecalculateIkeaDeliveryJob < ApplicationJob
  queue_as :default

  def perform
    Product.where(delivery_cost_manual: false).find_each do |product|
      product.recalculate_ikea_delivery!
    rescue StandardError => e
      Rails.logger.warn("[IkeaDelivery] recalc failed product_id=#{product.id}: #{e.class}: #{e.message}")
    end
  end
end
