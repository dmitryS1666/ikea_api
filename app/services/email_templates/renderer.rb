# frozen_string_literal: true

module EmailTemplates
  class Renderer
    UNSUBSCRIBE_TEMPLATES = %i[abandoned_cart welcome email_changed].freeze
    UNSUBSCRIBE_PLACEHOLDER = "{{ikeya_unsubscribe_url}}".freeze
    LEGACY_UNSUBSCRIBE_PLACEHOLDER = "{{unsubscribe_url}}".freeze

    # Labels in exported HTML may be split across lines/whitespace
    # ("Скидка\nпо\nпромокоду"). Match words with flexible whitespace.
    DISCOUNT_LABEL_PATTERN = /Скидка\s+по\s+промокоду/m
    DELIVERY_LABEL_PATTERN = /Доставка\s+в\s+Беларусь/m
    DISCOUNT_ROW_PATTERN = %r{
      <tr\b[^>]*>
      (?:(?!</tr>)[\s\S])*?
      (?:class="[^"]*\btotals-discount\b[^"]*"|#{DISCOUNT_LABEL_PATTERN.source})
      (?:(?!</tr>)[\s\S])*?
      </tr>
    }mx
    DELIVERY_VALUE_PATTERN = %r{
      (<tr\b[^>]*>
      (?:(?!</tr>)[\s\S])*?
      #{DELIVERY_LABEL_PATTERN.source}
      (?:(?!</tr>)[\s\S])*?
      <td\b[^>]*class="[^"]*\btotals-value[^"]*"[^>]*>)
      [\s\S]*?
      (</td>)
    }mx

    # Headers/subjects without template variables; preheaders are injected on render.
    TEMPLATES = {
      order_created: {
        file: "order_created.html",
        subject: "Ваш заказ находится в обработке",
        preheader: "Заказ находится в обработке. Сообщим, когда проверка будет завершена."
      },
      order_awaiting_payment: {
        file: "order_awaiting_payment.html",
        subject: "Ваш заказ ожидает оплаты",
        preheader: "Оплатите заказ, чтобы продолжить оформление."
      },
      order_placed: {
        file: "order_placed.html",
        subject: "Ваш заказ успешно оформлен",
        preheader: "Вы можете следить за статусом заказа в личном кабинете."
      },
      received_poland: {
        file: "received_poland.html",
        subject: "Ваш заказ поступил на склад в Польше",
        preheader: "Заказ получен на склад и готовится к дальнейшей доставке."
      },
      shipped_to_pvz: {
        file: "shipped_to_pvz.html",
        subject: "Ваш заказ в пути",
        preheader: "Заказ передан в доставку. Следите за его статусом в личном кабинете."
      },
      order_cancelled: {
        file: "order_cancelled.html",
        subject: "Ваш заказ отменён",
        preheader: "Оплата не поступила, поэтому заказ был отменён."
      },
      abandoned_cart: {
        file: "abandoned_cart.html",
        subject: "В вашей корзине остались товары",
        preheader: "Вернитесь к корзину, пока цены и наличие товаров не изменились."
      },
      welcome: {
        file: "welcome.html",
        subject: "Добро пожаловать в IKEYA- подтвердите Ваш e-mail",
        preheader: "Подтвердите адрес электронной почты, чтобы завершить регистрацию."
      },
      email_changed: {
        file: "email_changed.html",
        subject: "Подтвердите новый e-mail для аккаунта IKEYA",
        preheader: "Мы получили Ваш запрос на изменение адреса электронной почты."
      }
    }.freeze

    PREHEADER_FILLER = (("&nbsp;&zwnj;" * 50) + "&nbsp;").freeze

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

      def subject_for(template_key, **_locals)
        TEMPLATES.fetch(template_key).fetch(:subject)
      end

      def template_for_status(status)
        STATUS_TEMPLATE_MAP[status.to_s]
      end

      def template_for_order(order)
        if order.status.to_s == "shipped" && !order.delivery_type.to_s.in?(Order::PVZ_DELIVERY_TYPES)
          return nil
        end

        template_for_status(order.status)
      end
    end

    def initialize(template_key, **locals)
      @template_key = template_key
      @locals = locals
    end

    def render
      validate_unsubscribe_recipient!
      html = load_template.to_s.dup
      html = inject_preheader(html)
      html = apply_common_replacements(html)
      html = apply_template_specific_replacements(html)
      html = apply_fallback_links(html)
      html = apply_unsubscribe_link(html)
      ensure_unsubscribe_link_resolved!(html)
      html
    end

    private

    attr_reader :template_key, :locals

    def load_template
      config = TEMPLATES.fetch(template_key)
      path = Rails.root.join("app/views/email_templates", config[:file])
      File.read(path)
    end

    def inject_preheader(html)
      text = TEMPLATES.fetch(template_key)[:preheader]
      return html if text.blank?

      escaped = ERB::Util.html_escape(text)
      block = %(<div style="display:none!important;visibility:hidden;mso-hide:all;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;">#{escaped}#{PREHEADER_FILLER}</div>)

      if html.match?(/<body\b[^>]*>/im)
        html.sub(/<body\b[^>]*>/im) { |opening| "#{opening}#{block}" }
      else
        "#{block}#{html}"
      end
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

      html.gsub!("{{webversion}}", escaped)
      html.gsub!('href="#"', "href=\"#{escaped}\"")
      html.gsub!("href='#'", "href='#{escaped}'")
      html
    end

    def apply_unsubscribe_link(html)
      return html unless UNSUBSCRIBE_TEMPLATES.include?(template_key)

      url = ERB::Util.html_escape(MarketingUnsubscribeService.url_for(user))

      if html.include?(UNSUBSCRIBE_PLACEHOLDER)
        html.gsub!(UNSUBSCRIBE_PLACEHOLDER, url)
        return html
      end

      existing_pattern = /<a\b(?=[^>]*\bclass=(['"])[^'"]*\bunsubscribe-link\b[^'"]*\1)[^>]*>/i

      if html.match?(existing_pattern)
        html.gsub!(existing_pattern) do |tag|
          if tag.match?(/\bhref=(['"])[^'"]*\1/i)
            tag.sub(/\bhref=(['"])[^'"]*\1/i, "href=\"#{url}\"")
          else
            tag.sub(/>\z/, " href=\"#{url}\">")
          end
        end
        return html
      end

      block = <<~HTML
        <table role="presentation" cellspacing="0" cellpadding="0" width="100%" style="border-collapse: collapse; background-color: #F5F5F5;">
          <tr>
            <td align="center" style="padding: 0 24px 24px;">
              <a class="unsubscribe-link" href="#{url}" rel="noopener noreferrer" style="display: inline-block; padding: 9px 18px; border: 1px solid #9E9E9E; border-radius: 6px; font-family: Arial, sans-serif; font-size: 12px; line-height: 16px; color: #666C71; text-decoration: none;">Отписаться от рассылки</a>
            </td>
          </tr>
        </table>
      HTML

      html.include?("</body>") ? html.sub("</body>", "#{block}</body>") : "#{html}#{block}"
    end

    def validate_unsubscribe_recipient!
      return unless UNSUBSCRIBE_TEMPLATES.include?(template_key)
      return if user&.persisted? && user.email.present?

      raise ArgumentError, "persisted user with email is required for #{template_key} unsubscribe link"
    end

    def ensure_unsubscribe_link_resolved!(html)
      unresolved = [UNSUBSCRIBE_PLACEHOLDER, LEGACY_UNSUBSCRIBE_PLACEHOLDER].find do |placeholder|
        html.include?(placeholder)
      end
      return unless unresolved

      raise ArgumentError, "unresolved unsubscribe placeholder #{unresolved} in #{template_key} template"
    end

    def apply_order_replacements(html)
      return html unless order

      built = EmailTemplates::OrderItemsBuilder.call(order)
      details = EmailTemplates::OrderDetailsBuilder.call(order, template_key:)
      replace_order_items_block!(html, built[:items_html])
      apply_totals!(html, built[:totals_html])
      apply_order_details!(html, details)

      replace_status_button_link!(html, order_cta_url)
      replace_class_link!(html, "check-link", order_account_link_url)
      replace_class_link!(html, "customs-duty-link", customs_help_url)
      apply_customs_duty!(html, built[:totals_html])

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
        updated.gsub!(DISCOUNT_ROW_PATTERN, "")
      else
        updated.sub!(DISCOUNT_ROW_PATTERN, totals[:discount_row].strip)
      end

      if updated.match?(DELIVERY_LABEL_PATTERN)
        updated.sub!(DELIVERY_VALUE_PATTERN, "\\1#{totals[:delivery_price]}\\2")
      end

      html.sub!(totals_section_pattern, updated)

      html.gsub!(/<span class="span-total-value"[^>]*>[\s\S]*?<\/span>/m, "<span class=\"span-total-value\">#{totals[:grand_total]}</span>")
      html
    end

    def apply_order_details!(html, details)
      replace_delivery_icon!(html, details[:delivery_icon_url])
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

    def replace_delivery_icon!(html, icon_url)
      return html if icon_url.blank?

      section = html[warehouse_section_pattern]
      return html unless section

      escaped = ERB::Util.html_escape(icon_url.to_s)
      updated = section.sub(
        %r{<img\b(?=[^>]*\balt=(['"])delivery_img\1)[^>]*>}i
      ) do |tag|
        if tag.match?(/\bsrc=(['"])[^'"]*\1/i)
          tag.sub(/\bsrc=(['"])[^'"]*\1/i, "src=\"#{escaped}\"")
        else
          tag.sub(/\A<img\b/i, "<img src=\"#{escaped}\"")
        end
      end

      html.sub!(warehouse_section_pattern, updated)
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

    def replace_class_link!(html, css_class, url)
      escaped = ERB::Util.html_escape(url)
      html.gsub!(
        /<a\b(?=[^>]*\bclass=(['"])[^'"]*\b#{Regexp.escape(css_class)}\b[^'"]*\1)(?=[^>]*\bhref=(['"])#\2)[^>]*>/i
      ) do |tag|
        tag.sub(/\bhref=(['"])#\1/i, "href=\"#{escaped}\"")
      end
    end

    def order_cta_url
      case template_key
      when :order_cancelled
        OrderReorderLinkService.url_for(order)
      when :order_awaiting_payment
        order.payment_url.presence || profile_order_url
      when :abandoned_cart
        "#{public_site_url}/cart"
      else
        profile_order_url
      end
    end

    # «Узнать статус» / info-box in order emails → конкретный заказ в ЛК.
    def order_account_link_url
      profile_order_url
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
