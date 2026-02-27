# Задача для исправления отсутствующих изображений продуктов
class FixMissingImagesJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('fix_missing_images', limit: limit)
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('fix_missing_images', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: 0,
      fixed: 0,
      errors: 0
    }
    
    begin
      products = Product.where.not(images: [nil, "", "[]"])
      products = products.limit(limit) if limit
      
      total = products.count
      
      products.find_each do |product|
        # Проверяем, не остановлена ли задача
        check_task_not_stopped!(task)
        
        begin
          # Получаем список локальных путей
          local_images = begin
            JSON.parse(product.local_images || "[]")
          rescue
            []
          end
          
          # Проверяем наличие файлов на диске
          missing_any = local_images.any? do |path|
            !File.exist?(Rails.root.join('public', path.sub(/^\//, '')))
          end
          
          # Если хотя бы одной картинки нет на диске или список пуст при наличии оригинальных URL
          if missing_any || (local_images.empty? && product.images.present?)
            # Получаем оригинальные URL
            original_urls = begin
              JSON.parse(product.images || "[]")
            rescue
              []
            end
            
            if original_urls.any?
              # Очищаем битые пути перед перекачкой
              valid_local = local_images.select do |path|
                File.exist?(Rails.root.join('public', path.sub(/^\//, '')))
              end
              
              product.update_column(:local_images, valid_local.to_json)
              
              # Запускаем штатный загрузчик
              ImageDownloader.download_product_images(product, original_urls)
              stats[:fixed] += 1
              task.increment_updated!
            end
          end
          
          stats[:processed] += 1
          task.increment_processed!
        rescue => e
          Rails.logger.error "Error fixing images for product #{product.sku}: #{e.message}"
          stats[:errors] += 1
          task.increment_errors!
        end
      end
      
      # Мапим fixed на updated для ParserTask
      task.mark_as_completed!(stats.merge(updated: stats[:fixed]))
      stats[:duration] = Time.current - start_time
      notify_completed('fix_missing_images', stats)
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "FixMissingImagesJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "FixMissingImagesJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('fix_missing_images', e)
      raise
    end
  end
end
