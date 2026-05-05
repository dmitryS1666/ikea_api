class PaymentController < ApplicationController
  # WebPay returns user here after payment completion.
  # We forward to the orders page and keep original query params (wsb_*).
  def success
    process_webpay_return!
    target = ENV.fetch('WEBPAY_SUCCESS_REDIRECT_URL', '/account/orders')
    redirect_to build_redirect_url(target), allow_other_host: true
  end

  private

  def process_webpay_return!
    order_number = params[:wsb_order_num].to_s.strip
    transaction_id = params[:wsb_tid].to_s.strip
    return if order_number.blank? || transaction_id.blank?

    order = Order.find_by(payment_order_number: order_number)
    return unless order

    WebpayPaymentCompletionService.complete_for_order_with_transaction!(
      order: order,
      transaction_id: transaction_id
    )
  rescue StandardError => e
    Rails.logger.warn("[Payment success] WebPay completion skipped: #{e.class} #{e.message}")
  end

  def build_redirect_url(target)
    uri = URI.parse(target)
    return target if request.query_string.blank?

    separator = uri.query.present? ? '&' : '?'
    "#{target}#{separator}#{request.query_string}"
  rescue URI::InvalidURIError
    fallback = '/account/orders'
    return fallback if request.query_string.blank?

    "#{fallback}?#{request.query_string}"
  end
end
