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

      html.gsub!(/Здравствуйте,\s*Имя/m, "Здравствуйте, #{user_greeting}")
      html.gsub!(/>\s*Имя\s*</, ">#{user_greeting}<")
      html.gsub!(/Имя\s*<\/span>/m, "#{user_greeting}</span>")

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
      details = EmailTemplates::OrderDetailsBuilder.call(order, template_key:)
      replace_order_items_block!(html, built[:items_html])
      apply_totals!(html, built[:totals_html])
      apply_order_details!(html, details)

      cta_url = template_key == :order_cancelled ? cart_url : profile_order_url
      replace_status_button_link!(html, cta_url)
      html.gsub!('class="check-link" href="#"', "class=\"check-link\" href=\"#{ERB::Util.html_escape(profile_orders_url)}\"")
      html.gsub!('class="customs-duty-link" href="#"', "class=\"customs-duty-link\" href=\"#{ERB::Util.html_escape(customs_help_url)}\"")
      apply_customs_duty!(html, built[:totals_html])

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
      totals_section_pattern = /(<!-- ORDER: totals -->)[\s\S]*?(<!-- ORDER: totals spacer -->)/m
      return html unless html.match?(totals_section_pattern)

      section = html[totals_section_pattern]
      updated = section.dup

      updated.gsub!(/<span class="span-count"[^>]*>[\s\S]*?<\/span>/m, "<span class=\"span-count\">#{totals[:items_count_label]}</span>")
      updated.sub!(/<span class="span-price"[^>]*>[\s\S]*?<\/span>/m, "<span class=\"span-price\">#{totals[:items_total]}</span>")

      if totals[:discount_row].blank?
        updated.gsub!(%r{<tr>(?:(?!</tr>)[\s\S])*Скидка по промокоду(?:(?!</tr>)[\s\S])*</tr>}m, "")
      else
        updated.sub!(
          %r{<tr>(?:(?!</tr>)[\s\S])*Скидка по промокоду(?:(?!</tr>)[\s\S])*</tr>}m,
          totals[:discount_row].strip
        )
      end

      if updated.include?("Доставка в Беларусь")
        updated.sub!(
          %r{(<tr>(?:(?!</tr>)[\s\S])*Доставка в Беларусь(?:(?!</tr>)[\s\S])*<td class="totals-value[^"]*"[^>]*>)[\s\S]*?(</td>)}m,
          "\\1#{totals[:delivery_price]}\\2"
        )
      end

      html.sub!(totals_section_pattern, updated)

      html.gsub!(/<span class="span-total-value"[^>]*>[\s\S]*?<\/span>/m, "<span class=\"span-total-value\">#{totals[:grand_total]}</span>")
      html
    end

    def apply_order_details!(html, details)
      replace_first_paragraph_content!(html, "warehouse-address", details[:delivery_address], scope: warehouse_section_pattern)
      replace_first_paragraph_content!(html, "warehouse-address-sub", details[:delivery_subtitle], scope: warehouse_section_pattern)

      replace_first_paragraph_content!(html, "warehouse-address", details[:payment_method_label], scope: payment_section_pattern)
      replace_payment_status!(html, details)

      if details[:services_present]
        replace_services_items!(html, details[:service_items_html])
      else
        remove_services_sections!(html)
      end

      html
    end

    def warehouse_section_pattern
      /<!-- WAREHOUSE -->.*?<!-- WAREHOUSE(?:_PAYMENT)?_CONDITIONS_SERVICES: divider 1 -->/m
    end

    def payment_section_pattern
      /<!-- PAYMENT -->.*?<!-- PAYMENT to CONDITIONS: gap 8px -->/m
    end

    def replace_first_paragraph_content!(html, css_class, content, scope: nil)
      escaped = ERB::Util.html_escape(content.to_s)
      target = scope ? html[scope] : html
      return html unless target

      updated = target.sub(
        %r{<p\b(?=[^>]*\bclass=(['"])[^'"]*\b#{Regexp.escape(css_class)}\b[^'"]*\1)[^>]*>[\s\S]*?</p>}m
      ) do |paragraph|
        paragraph.sub(/>[\s\S]*?</m, ">#{escaped}<")
      end

      if scope
        html.sub!(scope, updated)
      else
        html.replace(updated)
      end
      html
    end

    def replace_payment_status!(html, details)
      pattern = %r{<p\b(?=[^>]*\bclass=(['"])[^'"]*\bwarehouse-address-sub\b[^'"]*\1)(?=[^>]*\bpayment-status-(?:green|red)\b)[^>]*>[\s\S]*?</p>}m
      color = details[:payment_status_class] == "payment-status-green" ? "#00910A" : "#B71C1C"
      replacement = <<~HTML.strip
        <p class="warehouse-address-sub #{details[:payment_status_class]}" style='font-family: "HelveticaNeueCyr", Arial, sans-serif; font-size: 14px; line-height: 20px; color: #{color} !important; letter-spacing: 0.25px; margin: 4px 0 0 0'>#{ERB::Util.html_escape(details[:payment_status_label])}</p>
      HTML

      if html.match?(payment_section_pattern)
        section = html[payment_section_pattern]
        html.sub!(payment_section_pattern, section.sub(pattern, replacement))
      else
        html.sub!(pattern, replacement)
      end
    end

    def replace_services_items!(html, service_items_html)
      pattern = %r{(<!-- SERVICES -->[\s\S]*?<p class="services-text services-heading"[^>]*>[\s\S]*?</p>)([\s\S]*?)(</td>)}m
      return html unless html.match?(pattern)

      html.sub!(pattern, "\\1#{service_items_html}\\3")
    end

    def remove_services_sections!(html)
      html.gsub!(
        %r{<!-- PAYMENT to CONDITIONS: gap 8px -->[\s\S]*?<!-- SERVICES bottom spacer 8px -->[\s\S]*?</table>}m,
        ""
      )
      html
    end

    def replace_status_button_link!(html, url)
      escaped = ERB::Util.html_escape(url)
      html.gsub!(
        /<a\b(?=[^>]*\bclass=(['"])[^'"]*\bstatus-btn\b[^'"]*\1)(?=[^>]*\bhref=(['"])#\2)[^>]*>/i
      ) do |tag|
        tag.sub(/\bhref=(['"])#\1/i, "href=\"#{escaped}\"")
      end
    end

    def apply_customs_duty!(html, totals)
      customs_amount = totals[:customs_total].to_s
      if customs_amount.blank?
        html.gsub!(%r{<!-- CUSTOMS_DUTY -->.*?<!-- /CUSTOMS_DUTY -->}m, "")
        html.gsub!(%r{<table[^>]*class="wrapper customs-duty"[^>]*>.*?</table>}m, "")
        return
      end

      html.gsub!(/<span class="customs-duty-amount"[^>]*>[\s\S]*?<\/span>/m, "<span class=\"customs-duty-amount\">#{customs_amount}</span>")
    end

    def order
      locals[:order]
    end

    def user
      locals[:user] || order&.user
    end

    def user_greeting
      given_name_from_full_name(order&.full_name).presence ||
        user&.first_name_display.presence ||
        user&.username.presence ||
        "клиент"
    end

    def given_name_from_full_name(full_name)
      parts = full_name.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
      return if parts.empty?

      parts.length >= 2 ? parts[1] : parts.first
    end

    def order_number
      order&.public_uid
    end

    def public_site_url
      Seo::PublicSiteUrl.resolve
    end

    def profile_order_url
      return profile_orders_url if order_number.blank?

      "#{public_site_url}/profile/orders/#{order_number}"
    end

    def profile_orders_url
      "#{public_site_url}/profile/orders"
    end

    def cart_url
      "#{public_site_url}/cart"
    end

    def customs_help_url
      "#{public_site_url}/help/customs/"
    end

    def verification_pixel_url
      locals[:verification_pixel_url]
    end
  end
end
