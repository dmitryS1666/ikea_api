# Задача для перевода фильтров категорий
class TranslateCategoryFiltersJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil, force: false)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('translate_category_filters', limit: limit)
    
    # Сбрасываем прогресс, если запрошен сброс (используем force как флаг сброса в данном контексте)
    task.reset_task! if force
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('translate_category_filters', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: task.processed || 0,
      updated: task.updated || 0,
      errors: task.error_count || 0
    }
    
    begin
      # Ищем категории, у которых есть фильтры
      # Если не force, выбираем только те, у кого еще нет русского перевода
      categories = if force
                     Category.where("available_filters IS NOT NULL AND available_filters::text <> '[]'")
                   else
                     Category.where("available_filters IS NOT NULL AND available_filters::text <> '[]'")
                             .where("available_filters_ru IS NULL OR available_filters_ru::text = '[]'")
                   end

      total_count = categories.count
      Rails.logger.info "Starting TranslateCategoryFiltersJob for #{total_count} categories..."

      processed_count = 0

      categories.find_each(batch_size: 10) do |category|
        break if limit && processed_count >= limit
        
        # Проверяем остановку после каждой категории
        check_task_not_stopped!(task)

        begin
          if Categories::FilterTranslationService.run(category, force: force)
            stats[:updated] += 1
            task.increment_updated!
          end
          
          stats[:processed] += 1
          processed_count += 1
          task.increment_processed!
          
        rescue => e
          Rails.logger.error "Error translating filters for category #{category.ikea_id}: #{e.message}"
          stats[:errors] += 1
          task.increment_errors!
        end
      end
      
      task.mark_as_completed!(stats)
      stats[:duration] = Time.current - start_time
      notify_completed('translate_category_filters', stats)
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "TranslateCategoryFiltersJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "TranslateCategoryFiltersJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('translate_category_filters', e)
      raise
    end
  end
end
