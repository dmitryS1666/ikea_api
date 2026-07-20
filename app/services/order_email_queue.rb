# frozen_string_literal: true

# Per-order FIFO for transactional client emails.
# Checkout seeds [order_created, order_awaiting_payment]; status emails append
# and never jump ahead of an in-flight chain.
class OrderEmailQueue
  # Short pause after "в обработке" before "ожидает оплаты" (enough to catch fast payments).
  AFTER_ORDER_CREATED_WAIT = Integer(ENV.fetch("ORDER_EMAIL_CHAIN_WAIT_SECONDS", "20")).seconds
  # No artificial delay between later status emails — send as soon as previous is accepted.
  AFTER_OTHER_WAIT = Integer(ENV.fetch("ORDER_EMAIL_FOLLOWUP_WAIT_SECONDS", "0")).seconds

  class << self
    def enqueue!(order, template_keys)
      keys = Array(template_keys).map(&:to_s).reject(&:blank?)
      return if keys.empty? || order.blank?

      start_now = false
      order.with_lock do
        pending = Array(order.pending_order_email_keys).map(&:to_s)
        start_now = order.email_dispatch_locked_at.nil? && pending.empty?
        order.pending_order_email_keys = pending + keys
        order.email_dispatch_locked_at = Time.current if start_now
        order.save!
      end

      dispatch_next!(order, wait: 0) if start_now
    end

    def complete_and_continue!(order_id, previous_template_key:)
      order = Order.find_by(id: order_id)
      return if order.blank?

      dispatch_next!(order, wait: wait_after(previous_template_key))
    rescue StandardError => e
      Rails.logger.error(
        "[OrderEmailQueue] Failed to continue order=#{order_id} after #{previous_template_key}: #{e.class} #{e.message}"
      )
    end

    private

    def dispatch_next!(order, wait:)
      template_key = nil

      order.with_lock do
        pending = Array(order.pending_order_email_keys).map(&:to_s)
        template_key = pending.shift
        if template_key.blank?
          order.update!(pending_order_email_keys: [], email_dispatch_locked_at: nil)
          return
        end

        order.pending_order_email_keys = pending
        order.email_dispatch_locked_at = Time.current
        order.save!
      end

      PrepareOrderEmailJob.set(wait: wait).perform_later(
        template_key: template_key,
        order_id: order.id,
        continue_order_queue: true
      )
    end

    def wait_after(previous_template_key)
      case previous_template_key.to_s
      when "order_created"
        AFTER_ORDER_CREATED_WAIT
      else
        AFTER_OTHER_WAIT
      end
    end
  end
end
