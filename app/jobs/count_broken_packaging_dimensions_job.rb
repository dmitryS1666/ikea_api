# frozen_string_literal: true

class CountBrokenPackagingDimensionsJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("count_broken_packaging_dimensions", limit: limit)
    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == "pending"
    task.mark_as_running!

    notify_started("count_broken_packaging_dimensions", limit: limit)
    started_at = Time.current

    broken = 0
    total = 0

    scope = Product.order(:id)
    scope = scope.limit(limit.to_i) if limit.present? && limit.to_i.positive?

    scope.find_each(batch_size: 500) do |product|
      check_task_not_stopped!(task)
      broken += 1 if Products::PackagingDimensionsStatus.missing_full_packaging_dimensions?(product)
      total += 1
      task.increment_processed!
    end

    stats = {
      processed: total,
      updated: broken,
      errors: 0,
      duration: Time.current - started_at
    }

    task.update_payload!(
      "metric" => "missing_packaging_dimensions",
      "broken_count" => broken,
      "total_checked" => total,
      "percent" => total.zero? ? 0.0 : ((broken.to_f * 100.0 / total).round(2))
    )
    task.mark_as_completed!(stats)
    notify_completed("count_broken_packaging_dimensions", stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    notify_error("count_broken_packaging_dimensions", e)
    raise
  end
end

