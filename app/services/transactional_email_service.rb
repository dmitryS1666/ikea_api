# frozen_string_literal: true

class TransactionalEmailService
  # Письма о заказах всегда идут при наличии email.
  # Suppress / verify / marketing влияют только на маркетинг и письма подтверждения.
  MARKETING_OR_VERIFY_TEMPLATES = %i[welcome email_changed abandoned_cart].freeze

  class << self
    def send_template(
      template_key,
      to_email:,
      to_name: nil,
      next_order_email: nil,
      continue_order_queue: false,
      order_id: nil,
      **locals
    )
      return if to_email.blank?
      return if marketing_or_verify_blocked?(locals[:user], template_key)

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
      if continue_order_queue && order_id.present?
        payload[:continue_order_queue] = true
        payload[:order_id] = order_id
        payload[:template_key] = template_key.to_s
      end

      SendpulseEmailJob.perform_later(**payload)
    rescue StandardError => e
      Rails.logger.error("[TransactionalEmail] Failed to enqueue #{template_key} to #{to_email}: #{e.class} #{e.message}")
      raise
    end

    # Enqueues order emails into a per-order FIFO. Status emails append and wait;
    # the next template is prepared only after SendPulse accepts the previous one.
    def send_order_emails(template_keys, order, abandoned_cart_activity_at: nil, abandoned_cart_queued_at: nil)
      order = order.reload if order.persisted?
      keys = Array(template_keys).map { |key| key.to_s }.reject(&:blank?)
      return if keys.empty?

      first_key = keys.first.to_sym

      draft_allowed = %i[abandoned_cart order_created].include?(first_key)
      return if order.checkout_draft? && !draft_allowed
      return if !order.checkout_draft? && first_key == :abandoned_cart
      # Письма о заказах: достаточно наличия email (verify/subscribe/suppress не важны).
      return if order.user&.email.blank?

      if first_key == :abandoned_cart
        PrepareOrderEmailJob.perform_later(
          template_key: keys.first,
          order_id: order.id,
          abandoned_cart_activity_at: serialize_time(abandoned_cart_activity_at),
          abandoned_cart_queued_at: serialize_time(abandoned_cart_queued_at)
        )
        return
      end

      OrderEmailQueue.enqueue!(order, keys)
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
      return if user.email_suppressed?

      token = EmailVerificationService.issue_token!(user: user, email: user.email, purpose: "welcome")
      send_email_verification(user, token)
    end

    def send_email_verification(user, token_record)
      return if user.email_suppressed?

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
      return if user.email_suppressed?

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

    def marketing_or_verify_blocked?(user, template_key)
      return false unless MARKETING_OR_VERIFY_TEMPLATES.include?(template_key.to_sym)

      user.present? && user.email_suppressed?
    end

    def serialize_time(value)
      return if value.blank?

      value.respond_to?(:iso8601) ? value.iso8601(6) : value.to_s
    end

    def strip_html(html)
      html.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
    end
  end
end
