class WebpayPaymentCompletionService
  class << self
    def complete_from_notification(raw_params, remote_ip: nil)
      new(remote_ip: remote_ip).complete_from_notification(raw_params)
    end

    def complete_for_order_with_transaction!(order:, transaction_id:)
      new(remote_ip: nil).complete_for_order_with_transaction!(order, transaction_id)
    end
  end

  def initialize(remote_ip: nil)
    @remote_ip = remote_ip
  end

  def complete_from_notification(raw_params)
    p = stringify_keys(raw_params)
    unless WebpaySignatureService.notify_signature_valid?(p, webpay_config.secret_key)
      Rails.logger.warn('[Webpay notify] invalid signature')
      return :invalid_signature
    end

    unless trusted_notify_ip?
      Rails.logger.warn("[Webpay notify] untrusted IP #{@remote_ip}")
      return :untrusted_ip
    end

    unless payment_type_success?(p['payment_type'])
      Rails.logger.info("[Webpay notify] non-success payment_type=#{p['payment_type']}")
      return :ignored
    end

    order = Order.find_by(payment_order_number: p['site_order_id'].to_s)
    unless order
      Rails.logger.warn("[Webpay notify] order not found site_order_id=#{p['site_order_id']}")
      return :order_not_found
    end

    unless amount_matches?(order, p['amount'])
      Rails.logger.error("[Webpay notify] amount mismatch order=#{order.id}")
      return :amount_mismatch
    end

    unless currency_matches?(p['currency_id'])
      Rails.logger.error("[Webpay notify] currency mismatch order=#{order.id}")
      return :currency_mismatch
    end

    verify_notify_via_billing_api!(order, p['transaction_id'])

    apply_paid!(order, p['transaction_id'].to_s)
  end

  def complete_for_order_with_transaction!(order, transaction_id)
    return :billing_not_configured unless WebpayGetTransactionService.billing_configured?

    res = WebpayGetTransactionService.fetch(transaction_id)
    unless res.ok
      Rails.logger.warn("[Webpay confirm] get_transaction failed: #{res.error}")
      return :remote_failed
    end

    f = res.fields
    unless WebpaySignatureService.get_transaction_signature_valid?(f, webpay_config.secret_key)
      Rails.logger.warn('[Webpay confirm] invalid get_transaction signature')
      return :invalid_signature
    end

    unless payment_type_success?(f['payment_type'])
      return :not_paid
    end

    unless amount_matches?(order, f['amount'])
      return :amount_mismatch
    end

    unless currency_matches?(f['currency_id'])
      return :currency_mismatch
    end

    apply_paid!(order, f['transaction_id'].presence || transaction_id.to_s)
  end

  private

  # Signed server notify is authoritative; Billing API is an extra check when available.
  def verify_notify_via_billing_api!(order, transaction_id)
    return unless WebpayGetTransactionService.billing_configured?

    res = WebpayGetTransactionService.fetch(transaction_id)
    unless res.ok && verify_get_transaction_fields!(res.fields, order, transaction_id)
      Rails.logger.warn(
        "[Webpay notify] get_transaction verification failed: #{res.error} " \
        '(payment will still be accepted from signed notify)'
      )
    end
  end

  def verify_get_transaction_fields!(fields, order, expected_transaction_id)
    return false unless WebpaySignatureService.get_transaction_signature_valid?(fields, webpay_config.secret_key)
    return false unless payment_type_success?(fields['payment_type'])
    return false unless fields['transaction_id'].to_s == expected_transaction_id.to_s
    return false unless amount_matches?(order, fields['amount'])
    return false unless currency_matches?(fields['currency_id'])

    true
  end

  def stringify_keys(raw)
    h = {}
    raw.each { |k, v| h[k.to_s] = v.is_a?(Array) ? v.first : v }
    h
  end

  def webpay_config
    Rails.application.config.x.webpay
  end

  def trusted_notify_ip?
    trusted = webpay_config.notify_trusted_ips
    return true if trusted.blank?
    return false if @remote_ip.blank?

    trusted.any? { |ip| ip == @remote_ip }
  end

  def payment_type_success?(value)
    %w[1 4].include?(value.to_s)
  end

  def amount_matches?(order, amount_str)
    return false if amount_str.blank?

    BigDecimal(amount_str.to_s).round(2) == order.total_amount.to_d.round(2)
  rescue ArgumentError
    false
  end

  def currency_matches?(currency_id)
    currency_id.to_s.casecmp?(webpay_config.currency_id.to_s)
  end

  def apply_paid!(order, transaction_id)
    tid = transaction_id.to_s.strip
    return :invalid_transaction if tid.blank?

    outcome = :noop
    sync_crm = false
    Order.transaction do
      order.lock!
      order.reload
      if order.paid?
        outcome = order.webpay_transaction_id.to_s == tid ? :already_paid : :already_paid_other
      elsif order.checkout_draft?
        outcome = :invalid_state
      elsif !order.created?
        outcome = :invalid_state
      elsif Order.where.not(id: order.id).exists?(webpay_transaction_id: tid)
        outcome = :transaction_used
      else
        order.update!(
          status: :paid,
          webpay_transaction_id: tid,
          webpay_paid_at: Time.current
        )
        outcome = :paid
        sync_crm = true
      end
    end
    CrmSyncJob.perform_later('Order', order.id) if sync_crm
    outcome
  rescue ActiveRecord::RecordNotUnique
    :transaction_used
  end
end
