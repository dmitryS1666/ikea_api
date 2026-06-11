class CancelExpiredUnpaidOrdersJob < ApplicationJob
  queue_as :default

  def perform
    result = Order.cancel_expired_unpaid!

    Rails.logger.info(
      "CancelExpiredUnpaidOrdersJob: checked=#{result[:checked]}, " \
      "cancelled=#{result[:cancelled]}, cutoff_time=#{result[:cutoff_time].iso8601}"
    )

    result
  end
end
