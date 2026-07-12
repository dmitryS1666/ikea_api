# frozen_string_literal: true

class TransactionalEmailService
  class << self
    def send_template(template_key, to_email:, to_name: nil, **locals)
      return if to_email.blank?

      html = EmailTemplates::Renderer.render(template_key, **locals)
      subject = EmailTemplates::Renderer.subject_for(template_key)
      text = strip_html(html)

      SendpulseEmailJob.perform_later(
        to_email: to_email,
        to_name: to_name,
        subject: subject,
        html: html,
        text: text
      )
    rescue StandardError => e
      Rails.logger.error("[TransactionalEmail] Failed to enqueue #{template_key} to #{to_email}: #{e.class} #{e.message}")
      raise
    end

    def send_order_email(template_key, order, abandoned_cart_activity_at: nil, abandoned_cart_queued_at: nil)
      order = order.reload if order.persisted?
      key = template_key.to_sym

      return if order.checkout_draft? && key != :abandoned_cart
      return if !order.checkout_draft? && key == :abandoned_cart
      return if order.user&.email.blank?

      payload = {
        template_key: key.to_s,
        order_id: order.id
      }
      if key == :abandoned_cart
        payload[:abandoned_cart_activity_at] = serialize_time(abandoned_cart_activity_at)
        payload[:abandoned_cart_queued_at] = serialize_time(abandoned_cart_queued_at)
      end

      PrepareOrderEmailJob.perform_later(**payload)
    rescue StandardError => e
      Rails.logger.error(
        "[TransactionalEmail] Failed to enqueue #{template_key} for order=#{order&.id}: #{e.class} #{e.message}"
      )
      raise
    end

    def send_welcome(user)
      return if user.email.blank?

      token = EmailVerificationService.issue_token!(user: user, email: user.email, purpose: "welcome")
      send_template(
        :welcome,
        to_email: user.email,
        to_name: user.full_name,
        user: user,
        verify_email_url: EmailVerificationService.verify_url(token)
      )
    end

    def send_email_changed(user, new_email)
      return if new_email.blank?

      token = EmailVerificationService.issue_token!(user: user, email: new_email, purpose: "email_change")
      send_template(
        :email_changed,
        to_email: new_email,
        to_name: user.full_name,
        user: user,
        verify_email_url: EmailVerificationService.verify_url(token)
      )
    end

    private

    def serialize_time(value)
      return if value.blank?

      value.respond_to?(:iso8601) ? value.iso8601(6) : value.to_s
    end

    def strip_html(html)
      html.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
    end
  end
end
