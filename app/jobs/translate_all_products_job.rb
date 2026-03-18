# Задача для перевода всех продуктов через Google Translate
class TranslateAllProductsJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil, reset: false)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('translate_all_products', limit: limit)
    
    # Сбрасываем прогресс, если запрошен сброс
    task.reset_task! if reset
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('translate_all_products', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: task.processed || 0,
      updated: task.updated || 0,
      errors: task.error_count || 0
    }
    
    begin
      # Ищем все продукты, начиная с последнего обработанного (если есть в payload)
      last_id = task.payload['last_id']
      products = Product.all
      products = products.where("id > ?", last_id) if last_id

      # find_each игнорирует limit на отношении, поэтому считаем вручную
      processed_count = 0

      total_count = products.count
      Rails.logger.info "Starting TranslateAllProductsJob for #{total_count} products (starting from ID: #{last_id || 'begin'})..."

      # Используем пул соединений для параллельной обработки
      products.find_in_batches(batch_size: 2) do |batch|
        break if limit && processed_count >= limit

        promises = batch.map do |product|
          Concurrent::Promises.future(product) do |p|
            ActiveRecord::Base.connection_pool.with_connection do
              Products::FullTranslationService.run(p)
            rescue => e
              Rails.logger.error "Error translating product #{p.sku}: #{e.message}"
              :error
            end
          end
        end

        results = Concurrent::Promises.zip(*promises).value!

        results.each do |res|
          if res == :error
            stats[:errors] += 1
            task.increment_errors!
          elsif res
            stats[:updated] += 1
            task.increment_updated!
          end
          
          stats[:processed] += 1
          processed_count += 1
          task.increment_processed!
          
          break if limit && processed_count >= limit
        end

        # Сохраняем прогресс после каждой пачки
        last_processed_product = batch[results.size - 1]
        task.update_payload!('last_id' => last_processed_product.id) if last_processed_product

        # Проверяем остановку после каждой пачки
        check_task_not_stopped!(task)
      end
      
      task.mark_as_completed!(stats)
      stats[:duration] = Time.current - start_time
      notify_completed('translate_all_products', stats)
      Rails.logger.info "TranslateAllProductsJob finished. Processed: #{stats[:processed]}, Updated: #{stats[:updated]}, Errors: #{stats[:errors]}"
      
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info "TranslateAllProductsJob: Task #{task.id} was stopped manually, aborting"
        return
      end
      
      Rails.logger.error "TranslateAllProductsJob error: #{e.message}\n#{e.backtrace.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error('translate_all_products', e)
      raise
    end
  end
end
