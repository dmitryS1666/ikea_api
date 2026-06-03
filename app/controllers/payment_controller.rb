class PaymentController < ApplicationController
  skip_before_action :authenticate_user

  # WebPay returns user here after payment completion (route: /api/v1/payment/success).
  # Marks order paid when possible, then redirects to the storefront orders page.
  def success
    result = process_webpay_return!
    Rails.logger.info("[Payment success] completion=#{result}") if result
    redirect_to build_redirect_url(success_redirect_target), allow_other_host: true
  end

  private

  def process_webpay_return!
    order_number = params[:wsb_order_num].to_s.strip
    transaction_id = params[:wsb_tid].to_s.strip
    return nil if order_number.blank? || transaction_id.blank?

    order = Order.find_by(payment_order_number: order_number)
    return :order_not_found unless order

    WebpayPaymentCompletionService.complete_for_order_with_transaction!(
      order: order,
      transaction_id: transaction_id
    )
  rescue StandardError => e
    Rails.logger.warn("[Payment success] WebPay completion skipped: #{e.class} #{e.message}")
    :error
  end

  def success_redirect_target
    explicit = ENV['WEBPAY_SUCCESS_REDIRECT_URL'].to_s.strip
    return normalize_storefront_success_url(explicit) if explicit.present?

    site = Seo::PublicSiteUrl.resolve.to_s.strip.chomp('/')
    "#{site}/profile/orders"
  end

  def normalize_storefront_success_url(target)
    uri = URI.parse(target)
    path = uri.path.to_s.delete_suffix('/')

    if path.casecmp?('/account/orders')
      uri.path = '/profile/orders'
      uri.to_s
    else
      target
    end
  rescue URI::InvalidURIError
    target
  end

  def build_redirect_url(target)
    uri = URI.parse(target)
    return target if request.query_string.blank?

    separator = uri.query.present? ? '&' : '?'
    "#{target}#{separator}#{request.query_string}"
  rescue URI::InvalidURIError
    fallback = '/profile/orders'
    return fallback if request.query_string.blank?

    "#{fallback}?#{request.query_string}"
  end
end
