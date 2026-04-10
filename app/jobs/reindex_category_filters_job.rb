class ReindexCategoryFiltersJob < ApplicationJob
  queue_as :parser

  # category_id — ikea_id категории; task_id — опционально, для отображения в ParserTask (админка «Управление парсером»)
  def perform(category_id, task_id: nil)
    task = ParserTask.find_by(id: task_id) if task_id.present?
    category = Category.find_by(ikea_id: category_id.to_s)
    unless category
      msg = "Категория не найдена: #{category_id}"
      Rails.logger.error "ReindexCategoryFiltersJob: #{msg}"
      task&.mark_as_failed!(msg)
      return
    end

    task&.mark_as_running!
    Products::FilterValuesIndexer.new(category).reindex!
    task&.mark_as_completed!(processed: 1, updated: 1)
  rescue StandardError => e
    Rails.logger.error "ReindexCategoryFiltersJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}"
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end
end
