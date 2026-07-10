# frozen_string_literal: true

module EmailTemplates
  class OrderDetailsBuilder
    PAYMENT_METHOD_LABELS = {
      "card" => "Оплата картой онлайн",
      "installment" => "Оплата в рассрочку",
      "qr" => "Оплата QR-кодом",
      "erip" => "Оплата через ЕРИП",
      "oplati" => "Оплати"
    }.freeze

    DELIVERY_SUBTITLES = {
      DeliveryTypeNormalizer::EUROPOST_PICKUP => "Европочта",
      DeliveryTypeNormalizer::COURIER => "Курьерская доставка",
      DeliveryTypeNormalizer::IKEYA_DELIVERY => "Доставка IKEYA"
    }.freeze

    UNPAID_TEMPLATE_KEYS = %i[order_created order_awaiting_payment].freeze

    def self.call(order, template_key:)
      new(order, template_key:).call
    end

    def initialize(order, template_key:)
      @order = order
      @template_key = template_key
    end

    def call
      {
        delivery_address: delivery_address,
        delivery_subtitle: delivery_subtitle,
        payment_method_label: payment_method_label,
        payment_status_label: payment_status[:label],
        payment_status_class: payment_status[:css_class],
        service_items_html: service_items_html,
        services_present: service_labels.any?
      }
    end

    private

    attr_reader :order, :template_key

    def delivery_address
      OrderAddressFormatter.display(order).presence || "—"
    end

    def delivery_subtitle
      normalized = DeliveryTypeNormalizer.normalize(order.delivery_type)
      DELIVERY_SUBTITLES[normalized] || CheckoutPricingPresenter::DELIVERY_TITLES[normalized] || normalized
    end

    def payment_method_label
      code = order.payment_method.to_s.strip.downcase
      PAYMENT_METHOD_LABELS[code] || order.payment_method.presence || "—"
    end

    def payment_status
      if template_key == :order_cancelled
        { label: "Не оплачено", css_class: "payment-status-red" }
      elsif UNPAID_TEMPLATE_KEYS.include?(template_key) || !order_paid?
        { label: "Ожидает оплаты", css_class: "payment-status-red" }
      else
        { label: "Оплачено", css_class: "payment-status-green" }
      end
    end

    def order_paid?
      order.webpay_paid_at.present? || !%w[created processing confirmed].include?(order.status.to_s)
    end

    def service_labels
      @service_labels ||= OrderServicesFormatter.labels(order.address_json&.dig("services"))
    end

    def service_items_html
      return "" if service_labels.blank?

      service_labels.map.with_index do |label, index|
        margin = index == service_labels.length - 1 ? "margin-bottom: 0" : "margin: 0 0 4px 0"
        <<~HTML.strip
          <p class="services-item" style='font-family: "HelveticaNeueCyr", Arial, sans-serif; font-weight: 400; font-size: 14px; line-height: 20px; letter-spacing: 0.25px; color: #757575; #{margin}'>#{h(label)}</p>
        HTML
      end.join
    end

    def h(text)
      ERB::Util.html_escape(text.to_s)
    end
  end
end
