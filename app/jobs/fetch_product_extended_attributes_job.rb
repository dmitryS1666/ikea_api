# Задача для загрузки расширенных атрибутов продуктов
class FetchProductExtendedAttributesJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, product_id: nil, task_id: nil)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('extended_attributes', limit: limit)
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('extended_attributes', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: 0,
      updated: 0,
      errors: 0
    }
    
    begin
      products = if product_id
                   Product.where(sku: product_id)
                 else
                   # Ищем продукты с URL, но без расширенных атрибутов
                   Product.where.not(url: nil)
                          .where("url != ''")
                          .limit(limit || 1000)
                 end
      
      products.find_each do |product|
        break if limit && stats[:processed] >= limit
        
        # Проверяем, не остановлена ли задача
        check_task_not_stopped!(task)
        
        begin
          result = Products::ExtendedAttributesFetchService.fetch_for_product(product)
          if result[:updated]
            stats[:updated] += 1
            task.increment_updated!
          end
          stats[:processed] += 1
          task.increment_processed!
        rescue => e
          Rails.logger.error "Error fetching extended attributes for product #{product.sku}: #{e.message}"
          stats[:errors] += 1
          task.increment_errors!
        end
      end
      
      task.mark_as_completed!(stats)
      stats[:duration] = Time.current - start_time
      notify_completed('extended_attributes', stats)
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "FetchProductExtendedAttributesJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "FetchProductExtendedAttributesJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('extended_attributes', e)
      raise
    end
  end
end
