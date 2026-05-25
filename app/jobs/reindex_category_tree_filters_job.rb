# frozen_string_literal: true

# Переиндексирует ProductFilterValue для одной категории или всей ветки:
# родительская категория + все дочерние. Использует существующий Products::FilterValuesIndexer.
class ReindexCategoryTreeFiltersJob < ApplicationJob
  queue_as :parser

  TASK_TYPE = "category_filters_tree".freeze

  def perform(ikea_id, task_id: nil, include_descendants: true, parameters: nil)
    task = task_id.present? ? ParserTask.find_by(id: task_id) : create_parser_task(TASK_TYPE)
    task&.mark_as_running!

    root = Category.find_by(ikea_id: ikea_id.to_s)
    unless root
      message = "Категория не найдена: #{ikea_id}"
      Rails.logger.error("ReindexCategoryTreeFiltersJob: #{message}")
      task&.mark_as_failed!(message)
      return
    end

    ids = include_descendants ? root.self_and_descendant_ikea_ids : [root.ikea_id.to_s]
    stats = { processed: 0, updated: 0, errors: 0 }

    Category.where(ikea_id: ids).order(:ikea_id).find_each do |category|
      break if task && task_stopped?(task)

      begin
        Products::FilterValuesIndexer.new(category, parameters: parameters).reindex!
        stats[:processed] += 1
        stats[:updated] += 1
        task&.increment_processed!
        task&.increment_updated!
      rescue StandardError => e
        stats[:errors] += 1
        task&.increment_errors!
        Rails.logger.error(
          "ReindexCategoryTreeFiltersJob category=#{category.ikea_id} #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
        )
      end
    end

    task&.mark_as_completed!(stats)
  rescue StandardError => e
    Rails.logger.error("ReindexCategoryTreeFiltersJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end
end
