require 'digest/sha1'

class WebpayPaymentLinkService
  LINK_VALIDITY = 30.minutes

  Result = Struct.new(:action, :fields, :seed, keyword_init: true)

  class << self
    def issue_link!(order)
      token = SecureRandom.hex(16)
      order.tap do
        order.payment_link_token = token
        order.payment_order_number = ensure_order_number(order)
        order.payment_url = payment_link_url(order, token)
        order.payment_expires_at = LINK_VALIDITY.from_now
        order.save!
      end
    end

    def build_form(order:, seed: nil)
      seed ||= Time.current.to_i
      order_number = ensure_order_number(order)
      total = formatted_total(order.total_amount)
      signature = build_signature(seed, order_number, total)
      fields = base_fields(order, order_number, total, seed, signature)

      Result.new(
        action: webpay_config.payment_page_url,
        fields: fields,
        seed: seed
      )
    end

    private

    def base_fields(order, order_number, total, seed, signature)
      fields = {
        '*scart' => '',
        'wsb_version' => webpay_config.version,
        'wsb_language_id' => webpay_config.language_id,
        'wsb_storeid' => webpay_config.store_id,
        'wsb_store' => webpay_config.store_name,
        'wsb_order_num' => order_number,
        'wsb_test' => webpay_config.test_flag,
        'wsb_currency_id' => webpay_config.currency_id,
        'wsb_seed' => seed.to_s,
        'wsb_total' => total,
        'wsb_signature' => signature
      }

      if order.full_name.present?
        fields['wsb_customer_name'] = order.full_name
      end

      if order.phone.present?
        fields['wsb_phone'] = order.phone
      end

      if order.user&.email.present?
        fields['wsb_email'] = order.user.email
      end

      return_url = effective_return_url
      fields['wsb_return_url'] = return_url if return_url.present?

      cancel_url = effective_cancel_url
      fields['wsb_cancel_return_url'] = cancel_url if cancel_url.present?

      notify = effective_notify_url
      fields['wsb_notify_url'] = notify if notify.present?

      fields.merge!(cart_fields(total, order))
      fields
    end

    def cart_fields(total, order)
      {
        'wsb_invoice_item_name[0]' => "Заказ #{order.id}",
        'wsb_invoice_item_quantity[0]' => '1',
        'wsb_invoice_item_price[0]' => total
      }
    end

    def formatted_total(amount)
      sprintf('%.2f', amount.to_d)
    end

    def build_signature(seed, order_number, total)
      payload = [
        seed,
        webpay_config.store_id,
        order_number,
        webpay_config.test_flag,
        webpay_config.currency_id,
        total,
        webpay_config.secret_key
      ].join

      Digest::SHA1.hexdigest(payload)
    end

    def payment_link_url(order, token)
      base = webpay_config.link_base_url.to_s.chomp('/')
      "#{base}/api/v1/payment_links/#{order.id}?token=#{token}"
    end

    def ensure_order_number(order)
      return order.payment_order_number if order.payment_order_number.present?

      order.assign_attributes(payment_order_number: generate_order_number(order))
      order.payment_order_number
    end

    def generate_order_number(order)
      "ORDER-#{order.id}-#{SecureRandom.hex(4)}"
    end

    def effective_notify_url
      if webpay_config.notify_url.is_a?(String)
        s = webpay_config.notify_url.strip
        return s if s.present?

        return nil
      end

      api_base = webpay_config.link_base_url.to_s.strip.chomp('/')
      return nil if api_base.blank?

      "#{api_base}/api/v1/webhooks/webpay"
    end

    def effective_return_url
      WebpayReturnUrl.normalize(webpay_config.return_url, api_base: webpay_config.link_base_url)
    end

    def effective_cancel_url
      configured = webpay_config.cancel_url.to_s.strip
      return configured if configured.present?

      site = public_site_url
      return nil if site.blank?

      "#{site}/payment/cancel"
    end

    def public_site_url
      Seo::PublicSiteUrl.resolve.to_s.strip.chomp('/')
    rescue NameError, NoMethodError
      nil
    end

    def webpay_config
      Rails.application.config.x.webpay
    end
  end
end
