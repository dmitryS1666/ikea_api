# frozen_string_literal: true

# Сливает available_filters потомков в родительскую категорию (уникальные значения по id)
# и ставит ReindexCategoryFiltersJob для обновления product_filter_values у этой категории.
#
#   MergeParentCategoryFiltersJob.perform_later
#     — все не удалённые категории, у которых есть потомки
#
#   MergeParentCategoryFiltersJob.perform_later("20515")
#     — только указанная ikea_id
#
#   MergeParentCategoryFiltersJob.perform_later("20515", task_id: id, reindex: false)
class MergeParentCategoryFiltersJob < ApplicationJob
  queue_as :parser

  def perform(ikea_id = nil, task_id: nil, reindex: true)
    task = ParserTask.find_by(id: task_id) if task_id.present?
    task&.mark_as_running!

    stats = { processed: 0, updated: 0, errors: 0 }

    if ikea_id.present?
      run_single(ikea_id, task: task, reindex: reindex, stats: stats)
    else
      Category.not_deleted.find_each do |category|
        next if category.descendant_ikea_ids.empty?

        stats[:processed] += 1
        begin
          result = Categories::MergeDescendantAvailableFiltersService.new(category).call
          stats[:updated] += 1 if result.merge_changed
          ReindexCategoryFiltersJob.perform_later(category.ikea_id) if reindex && result.merge_changed
        rescue StandardError => e
          stats[:errors] += 1
          Rails.logger.error(
            "MergeParentCategoryFiltersJob category=#{category.ikea_id} #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
          )
        end
      end

      task&.mark_as_completed!(processed: stats[:processed], updated: stats[:updated], errors: stats[:errors])
    end
  rescue StandardError => e
    Rails.logger.error("MergeParentCategoryFiltersJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end

  private

  def run_single(ikea_id, task:, reindex:, stats:)
    category = Category.find_by(ikea_id: ikea_id.to_s)
    unless category
      msg = "Категория не найдена: #{ikea_id}"
      Rails.logger.error("MergeParentCategoryFiltersJob: #{msg}")
      task&.mark_as_failed!(msg)
      return
    end

    stats[:processed] = 1
    result = Categories::MergeDescendantAvailableFiltersService.new(category).call
    stats[:updated] = 1 if result.merge_changed
    ReindexCategoryFiltersJob.perform_later(category.ikea_id) if reindex && result.merge_changed

    task&.mark_as_completed!(processed: stats[:processed], updated: stats[:updated], errors: stats[:errors])
  rescue StandardError => e
    stats[:errors] = 1
    raise
  end
end
