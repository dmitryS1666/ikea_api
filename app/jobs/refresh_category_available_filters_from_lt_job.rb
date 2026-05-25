# frozen_string_literal: true

# Актуализирует available_filters категорий из LT-сайта IKEA и, при необходимости,
# ставит переиндексацию ProductFilterValue.
class RefreshCategoryAvailableFiltersFromLtJob < ApplicationJob
  queue_as :parser

  TASK_TYPE = "refresh_category_filters_lt".freeze

  def perform(ikea_id = nil, task_id: nil, include_descendants: false, reindex: false, ensure_series: true)
    task = task_id.present? ? ParserTask.find_by(id: task_id) : create_parser_task(TASK_TYPE)
    task&.mark_as_running!

    categories = categories_scope(ikea_id, include_descendants: include_descendants)
    stats = { processed: 0, updated: 0, errors: 0, missing_required: {} }

    categories.find_each do |category|
      break if task && task_stopped?(task)

      begin
        result = Categories::LtAvailableFiltersRefreshService.new(
          category,
          reindex: reindex,
          ensure_series: ensure_series
        ).call

        stats[:processed] += 1
        stats[:updated] += 1 if result.changed
        stats[:missing_required][category.ikea_id] = result.missing_parameters if result.missing_parameters.present?
        task&.increment_processed!
        task&.increment_updated! if result.changed
      rescue StandardError => e
        stats[:errors] += 1
        task&.increment_errors!
        Rails.logger.error(
          "RefreshCategoryAvailableFiltersFromLtJob category=#{category.ikea_id} #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
        )
      end
    end

    task&.update_payload!("missing_required" => stats[:missing_required]) if stats[:missing_required].present?
    task&.mark_as_completed!(processed: stats[:processed], updated: stats[:updated], errors: stats[:errors])
  rescue StandardError => e
    Rails.logger.error("RefreshCategoryAvailableFiltersFromLtJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end

  private

  def categories_scope(ikea_id, include_descendants:)
    return Category.not_deleted.order(:ikea_id) if ikea_id.blank?

    category = Category.find_by(ikea_id: ikea_id.to_s)
    raise ActiveRecord::RecordNotFound, "Категория не найдена: #{ikea_id}" unless category

    ids = include_descendants ? category.self_and_descendant_ikea_ids : [category.ikea_id.to_s]
    Category.where(ikea_id: ids).order(:ikea_id)
  end
end
