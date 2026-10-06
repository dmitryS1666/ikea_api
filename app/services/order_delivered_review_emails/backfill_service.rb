# frozen_string_literal: true

module OrderDeliveredReviewEmails
  # One-time / ops backfill for clients who already have status=completed
  # and have not yet received the "Ваш заказ доставлен" review request email.
  class BackfillService
    Result = Struct.new(
      :dry_run,
      :limit,
      :candidates,
      :enqueued,
      :skipped_no_email,
      :skipped_already_sent,
      :skipped_no_reviewable_items,
      :order_ids,
      keyword_init: true
    )

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(dry_run: true, limit: nil)
      @dry_run = dry_run
      @limit = limit.present? ? Integer(limit) : nil
    end

    def call
      enqueued = 0
      skipped_no_email = 0
      skipped_already_sent = 0
      skipped_no_reviewable_items = 0
      order_ids = []

      each_candidate_order do |order|
        if order.order_delivered_email_sent_at.present?
          skipped_already_sent += 1
          next
        end

        if order.user&.email.blank?
          skipped_no_email += 1
          next
        end

        unless reviewable_items?(order)
          skipped_no_reviewable_items += 1
          next
        end

        order_ids << order.id
        next if dry_run

        TransactionalEmailService.send_order_email(:order_delivered, order)
        enqueued += 1
      end

      Result.new(
        dry_run: dry_run,
        limit: limit,
        candidates: order_ids.size,
        enqueued: dry_run ? 0 : enqueued,
        skipped_no_email: skipped_no_email,
        skipped_already_sent: skipped_already_sent,
        skipped_no_reviewable_items: skipped_no_reviewable_items,
        order_ids: order_ids
      )
    end

    private

    attr_reader :dry_run, :limit

    def each_candidate_order
      relation = Order.includes(:user, :order_items)
                      .where(status: Order.statuses[:completed], checkout_draft: false)
                      .where(order_delivered_email_sent_at: nil)
                      .order(:id)

      if limit
        relation.limit(limit).each { |order| yield order }
      else
        relation.find_each { |order| yield order }
      end
    end

    def reviewable_items?(order)
      skus = order.order_items.map(&:product_sku).compact.uniq
      return false if skus.empty?

      reviewed = order.user.reviews.where(product_sku: skus).pluck(:product_sku)
      (skus - reviewed).any?
    end
  end
end
