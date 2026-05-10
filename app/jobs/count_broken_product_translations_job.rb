# frozen_string_literal: true

class CountBrokenProductTranslationsJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("count_broken_product_translations", limit: limit)
    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == "pending"
    task.mark_as_running!

    notify_started("count_broken_product_translations", limit: limit)
    started_at = Time.current

    suspect = 0
    total = 0
    sample_skus = []

    scope = Product.order(:id)
    scope = scope.limit(limit.to_i) if limit.present? && limit.to_i.positive?

    scope.find_each(batch_size: 200) do |product|
      check_task_not_stopped!(task)

      is_suspect = Products::SuspectedPolishInCustomerPayload.suspect?(product)

      if is_suspect
        suspect += 1
        sample_skus << product.sku if sample_skus.size < 20
      end

      total += 1
      task.increment_processed!
    end

    stats = {
      processed: total,
      updated: suspect,
      errors: 0,
      duration: Time.current - started_at
    }

    task.update_payload!(
      "metric" => "suspected_polish_in_api_full_attributes_payload",
      "broken_count" => suspect,
      "total_checked" => total,
      "percent" => total.zero? ? 0.0 : ((suspect.to_f * 100.0 / total).round(2)),
      "sample_skus" => sample_skus
    )
    task.mark_as_completed!(stats)
    notify_completed("count_broken_product_translations", stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    notify_error("count_broken_product_translations", e)
    raise
  end

end

