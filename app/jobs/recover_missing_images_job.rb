# Задача для поиска и восполнения отсутствующих ссылок на картинки продуктов
class RecoverMissingImagesJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('recover_missing_images', limit: limit)
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('recover_missing_images', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: 0,
      updated: 0,
      errors: 0
    }
    
    begin
      # Ищем продукты, у которых поле images пустое (равно [], "" или nil)
      products = Product.where("images IS NULL OR images = '[]' OR images = ''")
      
      products = products.limit(limit) if limit
      
      total = products.count
      Rails.logger.info "RecoverMissingImagesJob: Found #{total} products with missing image URLs"
      
      products.find_each do |product|
        # Проверяем, не остановлена ли задача
        check_task_not_stopped!(task)
        
        begin
          Rails.logger.info "RecoverMissingImagesJob: Processing product #{product.sku} (URL: #{product.url})"
          
          # Получаем данные через PlDetailsFetcher
          # Мы используем PlDetailsFetcher.fetch, который уже умеет работать через прокси
          pl_details = PlDetailsFetcher.fetch(product.url, use_headless: false)
          
          if pl_details.present? && pl_details[:images].present? && pl_details[:images].any?
            # Сохраняем найденные ссылки в поле images
            # Используем update_columns, чтобы не вызывать коллбэки (если не нужно)
            # Но здесь может быть полезно обновить images_total
            
            image_urls = pl_details[:images]
            product.update_columns(
              images: image_urls.to_json,
              images_total: image_urls.length
            )
            
            stats[:updated] += 1
            task.increment_updated!
            Rails.logger.info "RecoverMissingImagesJob: Found #{image_urls.length} images for product #{product.sku}"
          else
            Rails.logger.warn "RecoverMissingImagesJob: Images not found for product #{product.sku} at #{product.url}"
          end
          
          stats[:processed] += 1
          task.increment_processed!
        rescue => e
          Rails.logger.error "RecoverMissingImagesJob: Error processing product #{product.sku}: #{e.message}"
          stats[:errors] += 1
          task.increment_errors!
        end
      end
      
      task.mark_as_completed!(stats)
      stats[:duration] = Time.current - start_time
      notify_completed('recover_missing_images', stats)
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "RecoverMissingImagesJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "RecoverMissingImagesJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('recover_missing_images', e)
      raise
    end
  end
end
