# frozen_string_literal: true

module TransactionalEmailLogs
  class Preview
    Result = Struct.new(:html, :source, keyword_init: true)

    ORDER_TEMPLATES = %i[
      order_created
      order_awaiting_payment
      order_placed
      received_poland
      shipped_to_pvz
      order_delivered
      order_cancelled
      abandoned_cart
    ].freeze

    def self.call(log)
      new(log).call
    end

    def initialize(log)
      @log = log
    end

    def call
      if log.html_body.present?
        return Result.new(html: log.html_body, source: :stored)
      end

      html = rebuild
      return Result.new(html: html, source: :rebuilt) if html.present?

      Result.new(html: nil, source: :missing)
    end

    private

    attr_reader :log

    def rebuild
      return admin_order_html if log.template_key == "admin_order_created"

      key = log.template_key.to_sym
      return nil unless EmailTemplates::Renderer::TEMPLATES.key?(key)

      user = log.user || log.order&.user
      if EmailTemplates::Renderer::UNSUBSCRIBE_TEMPLATES.include?(key)
        return nil unless user&.persisted? && user.email.present?
      end
      return nil if ORDER_TEMPLATES.include?(key) && log.order.blank?

      locals = { user: user, order: log.order }
      if key.in?(%i[welcome email_changed])
        locals[:verify_email_url] = "#{Seo::PublicSiteUrl.resolve}/"
      end

      EmailTemplates::Renderer.render(key, **locals)
    rescue StandardError => e
      Rails.logger.warn("[TransactionalEmailLogs::Preview] log=#{log.id}: #{e.class} #{e.message}")
      nil
    end

    def admin_order_html
      return nil unless log.order

      OrderNotificationService.build_admin_order_created_html(log.order)
    end
  end
end
