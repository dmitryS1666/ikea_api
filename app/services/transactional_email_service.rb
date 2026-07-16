# frozen_string_literal: true

class TransactionalEmailService
  class << self
    def send_template(template_key, to_email:, to_name: nil, next_order_email: nil, **locals)
      return if to_email.blank?

      html = EmailTemplates::Renderer.render(template_key, **locals)
      subject = EmailTemplates::Renderer.subject_for(template_key, **locals)
      text = strip_html(html)

      payload = {
        to_email: to_email,
        to_name: to_name,
        subject: subject,
        html: html,
        text: text
      }
      payload[:next_order_email] = next_order_email if next_order_email.present?

      SendpulseEmailJob.perform_later(**payload)
    rescue StandardError => e
      Rails.logger.error("[TransactionalEmail] Failed to enqueue #{template_key} to #{to_email}: #{e.class} #{e.message}")
      raise
    end

    # Enqueues order emails as a chain: the next template is prepared only after
    # the previous one was accepted by SendPulse, so they arrive sequentially.
    def send_order_emails(template_keys, order, abandoned_cart_activity_at: nil, abandoned_cart_queued_at: nil)
      order = order.reload if order.persisted?
      keys = Array(template_keys).map { |key| key.to_s }.reject(&:blank?)
      return if keys.empty?

      first, *rest = keys
      key = first.to_sym

      return if order.checkout_draft? && key != :abandoned_cart
      return if !order.checkout_draft? && key == :abandoned_cart
      return if order.user&.email.blank?

      payload = {
        template_key: first,
        order_id: order.id,
        next_template_keys: rest
      }
      if key == :abandoned_cart
        payload[:abandoned_cart_activity_at] = serialize_time(abandoned_cart_activity_at)
        payload[:abandoned_cart_queued_at] = serialize_time(abandoned_cart_queued_at)
      end

      PrepareOrderEmailJob.perform_later(**payload)
    rescue StandardError => e
      Rails.logger.error(
        "[TransactionalEmail] Failed to enqueue #{template_keys.inspect} for order=#{order&.id}: #{e.class} #{e.message}"
      )
      raise
    end

    def send_order_email(template_key, order, abandoned_cart_activity_at: nil, abandoned_cart_queued_at: nil)
      send_order_emails(
        [template_key],
        order,
        abandoned_cart_activity_at: abandoned_cart_activity_at,
        abandoned_cart_queued_at: abandoned_cart_queued_at
      )
    end

    def send_welcome(user)
      return if user.email.blank?

      token = EmailVerificationService.issue_token!(user: user, email: user.email, purpose: "welcome")
      send_email_verification(user, token)
    end

    def send_email_verification(user, token_record)
      send_template(
        :welcome,
        to_email: token_record.email,
        to_name: user.full_name,
        user: user,
        verify_email_url: EmailVerificationService.verify_url(token_record)
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
