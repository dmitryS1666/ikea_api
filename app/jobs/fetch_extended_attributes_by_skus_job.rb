# Задача для загрузки расширенных атрибутов продуктов по списку SKU
class FetchExtendedAttributesBySkusJob < ApplicationJob
  queue_as :parser

  def perform(task_id:)
    task = ParserTask.find(task_id)
    payload = task.payload || {}
    skus_text = payload["skus"]
    
    skus = if skus_text.present?
             skus_text.split(/[\s,]+/).map(&:strip).reject(&:blank?)
           else
             []
           end
           
    if skus.empty?
      task.mark_as_failed!("No SKUs provided")
      return
    end

    task.update!(limit: skus.length)
    task.mark_as_running!
    
    notify_started('extended_attributes_by_skus', limit: skus.length)
    start_time = Time.current
    
    stats = {
      processed: 0,
      updated: 0,
      errors: 0
    }
    
    skus.each do |sku|
      # Проверяем, не остановлена ли задача
      break if task_stopped?(task)
      
      begin
        product = Product.find_by(sku: sku)
        if product
          result = Products::ExtendedAttributesFetchService.fetch_for_product(product)
          if result[:updated]
            stats[:updated] += 1
            task.increment_updated!
          end
        else
          Rails.logger.warn "FetchExtendedAttributesBySkusJob: Product with SKU #{sku} not found"
          stats[:errors] += 1
          task.increment_errors!
        end
        
        stats[:processed] += 1
        task.increment_processed!
      rescue => e
        Rails.logger.error "Error fetching extended attributes for SKU #{sku}: #{e.message}"
        stats[:errors] += 1
        task.increment_errors!
      end
    end
    
    task.mark_as_completed!(stats)
    stats[:duration] = Time.current - start_time
    notify_completed('extended_attributes_by_skus', stats)
    
  rescue StandardError => e
    if e.message == 'Task was stopped manually'
      Rails.logger.info "FetchExtendedAttributesBySkusJob: Task #{task.id} was stopped manually"
      return
    end
    
    Rails.logger.error "FetchExtendedAttributesBySkusJob error: #{e.message}\n#{e.backtrace.join("\n")}"
    task.mark_as_failed!(e.message)
    notify_error('extended_attributes_by_skus', e)
  end
end
