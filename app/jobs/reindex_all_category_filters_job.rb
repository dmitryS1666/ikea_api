class ReindexAllCategoryFiltersJob < ApplicationJob
  queue_as :parser

  def perform(task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task('category_filters')
    check_task_not_stopped!(task)
    task.mark_as_running!

    stats = {
      processed: 0,
      updated: 0,
      errors: 0
    }

    Category.find_each do |category|
      break if task_stopped?(task)

      begin
        Products::FilterValuesIndexer.new(category).reindex!
        stats[:processed] += 1
        stats[:updated] += 1
        task.increment_processed!
        task.increment_updated!
      rescue => e
        Rails.logger.error("ReindexAllCategoryFiltersJob category=#{category.ikea_id} error=#{e.class}: #{e.message}")
        stats[:errors] += 1
        task.increment_errors!
      end
    end

    task.mark_as_completed!(stats)
  rescue StandardError => e
    if e.message == 'Task was stopped manually'
      Rails.logger.info "ReindexAllCategoryFiltersJob: Task #{task.id} was stopped manually"
      return
    end

    Rails.logger.error "ReindexAllCategoryFiltersJob error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
    task.mark_as_failed!(e.message)
    notify_error('category_filters', e)
  end
end
