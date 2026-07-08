# frozen_string_literal: true

module EmailTemplates
  class Renderer
    TEMPLATES = {
      order_created: {
        file: "order_created.html",
        subject: "Ваш заказ создан"
      },
      order_awaiting_payment: {
        file: "order_awaiting_payment.html",
        subject: "Ваш заказ ожидает оплаты"
      },
      order_placed: {
        file: "order_placed.html",
        subject: "Ваш заказ оформлен"
      },
      received_poland: {
        file: "received_poland.html",
        subject: "Заказ получен на склад в Польше"
      },
      shipped_to_pvz: {
        file: "shipped_to_pvz.html",
        subject: "Заказ в доставке в ПВЗ"
      },
      order_cancelled: {
        file: "order_cancelled.html",
        subject: "Заказ отменён"
      },
      abandoned_cart: {
        file: "abandoned_cart.html",
        subject: "Вы не завершили оформление заказа"
      },
      welcome: {
        file: "welcome.html",
        subject: "Добро пожаловать в IKEYA"
      },
      email_changed: {
        file: "email_changed.html",
        subject: "Подтвердите ваш e-mail"
      }
    }.freeze

    STATUS_TEMPLATE_MAP = {
      "paid" => :order_placed,
      "received_poland" => :received_poland,
      "shipped" => :shipped_to_pvz,
      "cancelled" => :order_cancelled
    }.freeze

    class << self
      def render(template_key, **locals)
        new(template_key, **locals).render
      end

      def subject_for(template_key)
        TEMPLATES.fetch(template_key).fetch(:subject)
      end

      def template_for_status(status)
        STATUS_TEMPLATE_MAP[status.to_s]
      end
    end

    def initialize(template_key, **locals)
      @template_key = template_key
      @locals = locals
    end

    def render
      html = load_template
      html = apply_common_replacements(html)
      html = apply_template_specific_replacements(html)
      apply_fallback_links(html)
    end

    private

    attr_reader :template_key, :locals

    def load_template
      config = TEMPLATES.fetch(template_key)
      path = Rails.root.join("app/views/email_templates", config[:file])
      File.read(path)
    end

    def apply_common_replacements(html)
      html.gsub!("№1234567", "№#{order_number}") if order
      html.gsub!("№1234567", "") unless order

      html.gsub!("Здравствуйте, Имя", "Здравствуйте, #{user_greeting}")
      html.gsub!(/>\s*Имя\s*</, ">#{user_greeting}<")
      html.gsub!("Имя</span>", "#{user_greeting}</span>")

      if verification_pixel_url.present?
        html.sub!(
          'src="https://via.placeholder.com/600x1/EFEFEF/EFEFEF"',
          "src=\"#{ERB::Util.html_escape(verification_pixel_url)}\""
        )
      end

      html
    end

    def apply_template_specific_replacements(html)
      case template_key
      when :order_created, :order_awaiting_payment, :order_placed,
           :received_poland, :shipped_to_pvz, :order_cancelled, :abandoned_cart
        apply_order_replacements(html)
      when :welcome, :email_changed
        apply_verification_replacements(html)
      else
        html
      end
    end

    def apply_fallback_links(html)
      site_root = "#{public_site_url}/"
      escaped = ERB::Util.html_escape(site_root)

      html.gsub!('href="#"', "href=\"#{escaped}\"")
      html.gsub!("href='#'", "href='#{escaped}'")
      html
    end

    def apply_order_replacements(html)
      return html unless order

      built = EmailTemplates::OrderItemsBuilder.call(order)
      replace_order_items_block!(html, built[:items_html])
      apply_totals!(html, built[:totals_html])

      cta_url = template_key == :order_cancelled ? account_orders_url : account_order_url
      html.gsub!('class="status-btn" href="#"', "class=\"status-btn\" href=\"#{ERB::Util.html_escape(cta_url)}\"")
      html.gsub!('class="check-link" href="#"', "class=\"check-link\" href=\"#{ERB::Util.html_escape(account_order_url)}\"")
      html.gsub!('class="customs-duty-link" href="#"', "class=\"customs-duty-link\" href=\"#{ERB::Util.html_escape(customs_help_url)}\"")

      if template_key == :order_awaiting_payment && order.payment_url.present?
        payment_url = ERB::Util.html_escape(order.payment_url)
        html.sub!(/href="#"(?=[^>]*>Оплатить заказ<\/a>)/, "href=\"#{payment_url}\"")
      end

      if template_key == :abandoned_cart
        checkout_url = "#{public_site_url}/checkout"
        html.gsub!(
          'class="status-btn" href="#"',
          "class=\"status-btn\" href=\"#{ERB::Util.html_escape(checkout_url)}\""
        )
      end

      html
    end

    def apply_verification_replacements(html)
      verify_url = locals[:verify_email_url].to_s
      return html if verify_url.blank?

      escaped_verify_url = ERB::Util.html_escape(verify_url)
      html.gsub!(
        /<a\b(?=[^>]*\bclass=(['"])[^'"]*\bstatus-btn\b[^'"]*\1)(?=[^>]*\bhref=(['"])#\2)[^>]*>/i
      ) do |tag|
        tag.sub(/\bhref=(['"])#\1/i, "href=\"#{escaped_verify_url}\"")
      end
      html
    end

    def replace_order_items_block!(html, items_html)
      pattern = /<!-- ORDER: product 1 -->.*?<!-- ORDER: divider -->/m
      if html.match?(pattern)
        html.sub!(pattern, "#{items_html}<!-- ORDER: divider -->")
      end
    end

    def apply_totals!(html, totals)
      html.gsub!(/<span class="span-count">.*?<\/span>/m, "<span class=\"span-count\">#{totals[:items_count_label]}</span>")

      price_matches = html.scan(/<span class="span-price">.*?<\/span>/m)
      if price_matches.any?
        html.sub!(price_matches.first, "<span class=\"span-price\">#{totals[:items_total]}</span>")
      end

      html.gsub!(/<span class="span-total-value">.*?<\/span>/m, "<span class=\"span-total-value\">#{totals[:grand_total]}</span>")

      if totals[:discount_row].blank?
        html.gsub!(%r{<tr>\s*<td class="totals-label"[^>]*><span>Скидка по промокоду</span></td>.*?</tr>}m, "")
      else
        html.sub!(/<!-- ORDER: totals spacer -->/, "#{totals[:discount_row]}<!-- ORDER: totals spacer -->")
      end

      if html.include?("Доставка в Беларусь")
        html.sub!(
          /(<span>Доставка в Беларусь<\/span>.*?<td class="totals-value[^"]*"[^>]*>)(<span class="span-free">бесплатно<\/span>|<span class="span-price">[^<]*<\/span>)/m,
          "\\1#{totals[:delivery_price]}"
        )
      end
    end

    def order
      locals[:order]
    end

    def user
      locals[:user] || order&.user
    end

    def user_greeting
      user&.first_name_display.presence || user&.username.presence || "клиент"
    end

    def order_number
      order&.public_uid.presence || order&.id
    end

    def public_site_url
      Seo::PublicSiteUrl.resolve
    end

    def account_order_url
      "#{public_site_url}/account/orders/#{order_number}"
    end

    def account_orders_url
      "#{public_site_url}/account/orders"
    end

    def customs_help_url
      "#{public_site_url}/help/customs/"
    end

    def verification_pixel_url
      locals[:verification_pixel_url]
    end
  end
end
