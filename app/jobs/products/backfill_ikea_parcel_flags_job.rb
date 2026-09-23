# frozen_string_literal: true

# Разовый полный проход флага посылки и доставки IKEA. В расписание не ставится.
class Products::BackfillIkeaParcelFlagsJob < ApplicationJob
  queue_as :default

  def perform(skus = nil)
    result = Products::IkeaParcelFlagBackfill.call(skus: skus)
    Rails.logger.info("[IkeaParcel] stats=#{result[:stats].inspect} after=#{result[:after].inspect}")
    result
  end
end
