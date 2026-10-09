# frozen_string_literal: true

module TransactionalEmailLogs
  class Creator
    PREVIEW_LIMIT = 220

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(template_key:, to_email:, subject:, text: nil, html: nil, to_name: nil, user: nil, order: nil)
      @template_key = template_key.to_s
      @to_email = to_email.to_s
      @to_name = to_name
      @subject = subject.to_s
      @text = text
      @html = html
      @user = user
      @order = order
    end

    def call
      TransactionalEmailLog.create!(
        user: user || order&.user,
        order: order,
        to_email: to_email,
        to_name: to_name,
        template_key: template_key,
        subject: subject,
        preview_text: preview_text,
        html_body: html.presence,
        status: "queued",
        provider: "sendpulse",
        queued_at: Time.current,
        last_event_at: Time.current
      )
    end

    private

    attr_reader :template_key, :to_email, :to_name, :subject, :text, :html, :user, :order

    def preview_text
      source = text.to_s.presence || strip_html(html.to_s)
      source = source.gsub(/\s+/, " ").strip
      return subject if source.blank?

      source.truncate(PREVIEW_LIMIT)
    end

    def strip_html(value)
      value.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
    end
  end
end
