# frozen_string_literal: true

module EmailTemplates
  class OrderItemsBuilder
    PRODUCT_ROW_STYLE = <<~STYLE.squish
      mso-table-lspace: 0pt; mso-table-rspace: 0pt; border-collapse: collapse; border-spacing: 0
    STYLE

    def self.call(order)
      new(order).call
    end

    def initialize(order)
      @order = order
      @pricing = CheckoutPricingPresenter.for_order(order)
    end

    def call
      items_html = build_items_html
      totals_html = build_totals_html
      { items_html: items_html, totals_html: totals_html }
    end

    private

    attr_reader :order, :pricing

    def build_items_html
      lines = pricing&.dig(:items) || fallback_items
      return "" if lines.blank?

      lines.each_with_index.map do |line, index|
        spacer = index.positive? ? spacer_row : ""
        "#{spacer}#{product_row(line)}"
      end.join
    end

    def fallback_items
      order.order_items.includes(:product).map do |item|
        unit_price = item.price.to_f
        {
          sku: item.product_sku,
          quantity: item.quantity,
          pricing: {
            unit_price_new_byn: format("%.2f", unit_price),
            line_total_new_byn: format("%.2f", unit_price * item.quantity)
          }
        }
      end
    end

    def product_row(line)
      product = order.order_items.find { |oi| oi.product_sku == line[:sku] }&.product
      name = product&.small_desc_name.presence || product&.name_ru.presence || product&.name.presence || line[:sku]
      description = product_description(product)
      price = line.dig(:pricing, :line_total_new_byn) || line.dig(:pricing, :unit_price_new_byn) || "0.00"
      quantity = line[:quantity].to_i

      <<~HTML
        <!-- ORDER: product -->
        <table width="100%" cellspacing="0" cellpadding="0" style="#{PRODUCT_ROW_STYLE}">
          <tbody>
            <tr>
              <td class="product-name" style="padding: 0; margin: 0; font-family: HelveticaNeueCyr, Arial, sans-serif; font-weight: 600; font-style: normal; color: #181818; font-size: 12px; line-height: 16px; letter-spacing: 0.1px; text-align: left; vertical-align: top; width: 70%">#{h(name)}</td>
              <td class="product-price" style="padding: 0; margin: 0; font-family: HelveticaNeueCyr, Arial, sans-serif; font-weight: 600; font-style: normal; color: #181818; font-size: 14px; line-height: 20px; letter-spacing: 0.1px; text-align: right; vertical-align: top; width: 30%; white-space: nowrap">#{format_price(price)}</td>
            </tr>
            <tr>
              <td class="product-description" style="padding: 0; margin: 0; font-family: HelveticaNeueCyr, Arial, sans-serif; font-weight: 400; font-size: 14px; line-height: 20px; letter-spacing: 0.25px; color: #757575; text-align: left; vertical-align: top; padding-top: 2px">#{h(description)}</td>
              <td class="product-quantity" style="padding: 0; margin: 0; font-family: HelveticaNeueCyr, Arial, sans-serif; font-weight: 400; font-size: 12px; line-height: 16px; color: #757575; letter-spacing: 0.4px; text-align: right; vertical-align: top; padding-top: 2px; white-space: nowrap">#{quantity} шт.</td>
            </tr>
          </tbody>
        </table>
      HTML
    end

    def spacer_row
      <<~HTML
        <table width="100%" cellspacing="0" cellpadding="0" style="#{PRODUCT_ROW_STYLE}">
          <tbody><tr><td class="product-spacer" style="padding: 0; margin: 0; height: 16px"></td></tr></tbody>
        </table>
      HTML
    end

    def build_totals_html
      totals = pricing&.dig(:totals) || {}
      items_count = order.order_items.sum(:quantity)
      items_total = totals[:subtotal_new_byn] || order.order_items.sum { |i| i.price.to_f * i.quantity }.round(2)
      delivery_total = totals[:delivery_to_belarus_byn] || totals[:delivery_total_byn] || order.delivery_price
      discount = totals[:discount_total_byn].to_f
      grand_total = totals[:final_total_byn] || totals[:total_byn] || order.total_amount

      {
        items_count_label: items_count_label(items_count),
        items_total: format_price(items_total),
        delivery_label: delivery_label,
        delivery_price: delivery_price_html(delivery_total),
        discount_row: discount_row_html(discount),
        grand_total: format_price(grand_total)
      }
    end

    def items_count_label(count)
      n = count.to_i
      word = case n % 100
             when 11..14 then "товаров"
             else
               case n % 10
               when 1 then "товар"
               when 2..4 then "товара"
               else "товаров"
               end
             end
      "#{n} #{word}"
    end

    def delivery_label
      "Доставка в Беларусь"
    end

    def delivery_price_html(amount)
      value = amount.to_f
      if value <= 0
        '<span class="span-free">бесплатно</span>'
      else
        format_price(value)
      end
    end

    def discount_row_html(discount)
      return "" if discount.to_f <= 0

      <<~HTML
        <tr>
          <td class="totals-label" style="padding: 0; margin: 0; text-align: left"><span>Скидка по промокоду</span></td>
          <td class="totals-value totals-discount" style="padding: 0; margin: 0; text-align: right; white-space: nowrap; font-weight: 600; font-size: 14px; color: #CE0061 !important"><span class="span-discount">#{format_price(discount)}</span></td>
        </tr>
      HTML
    end

    def product_description(product)
      return "" unless product

      [product.dimensions_ru, product.dimensions].compact_blank.first.to_s
    end

    def format_price(value)
      "#{format('%.2f', value.to_f).tr('.', ',')} р."
    end

    def h(text)
      ERB::Util.html_escape(text.to_s)
    end
  end
end
