# Задача для исправления битых переводов продуктов
class RepairProductTranslationsJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('fix_translations', limit: limit)
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('fix_translations', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: 0,
      fixed: 0,
      errors: 0
    }
    
    begin
      fields_to_fix = ProductTranslationRepairService::FIELDS_TO_FIX
      
      # Ищем продукты, где хотя бы в одном из полей есть "translatedText"
      query_parts = fields_to_fix.map { |f| "#{f} LIKE '%translatedText%'" }
      query_parts << "full_attributes_ru::text LIKE '%translatedText%'"
      
      products = Product.where(query_parts.join(" OR "))
      products = products.limit(limit) if limit
      
      products.count
      
      products.find_each do |product|
        # Проверяем, не остановлена ли задача
        check_task_not_stopped!(task)
        
        begin
          res = ProductTranslationRepairService.repair_product(product)
          if res[:fixed]
            stats[:fixed] += 1
            task.increment_updated!
          end
          
          stats[:processed] += 1
          task.increment_processed!
        rescue => e
          Rails.logger.error "Error fixing translations for product #{product.sku}: #{e.message}"
          stats[:errors] += 1
          task.increment_errors!
        end
      end
      
      # Мапим fixed на updated для ParserTask
      task.mark_as_completed!(stats.merge(updated: stats[:fixed]))
      stats[:duration] = Time.current - start_time
      notify_completed('fix_translations', stats)
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "RepairProductTranslationsJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "RepairProductTranslationsJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('fix_translations', e)
      raise
    end
  end
end
