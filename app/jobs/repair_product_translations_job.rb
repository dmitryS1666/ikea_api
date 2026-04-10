# Задача для исправления битых переводов продуктов
class RepairProductTranslationsJob < ApplicationJob
  queue_as :parser

  def perform(limit: nil, task_id: nil, reset: false)
    # Если task_id передан, используем существующую задачу, иначе создаем новую
    task = task_id ? ParserTask.find(task_id) : create_parser_task('fix_translations', limit: limit)
    
    # Сбрасываем прогресс, если запрошен сброс
    task.reset_task! if reset
    
    # Проверяем, не остановлена ли задача перед началом выполнения
    check_task_not_stopped!(task)
    
    task.mark_as_running!
    
    notify_started('fix_translations', limit: limit)
    start_time = Time.current
    
    stats = {
      processed: task.processed || 0,
      fixed: task.updated || 0, # В ParserTask fixed мапится на updated
      errors: task.error_count || 0
    }
    
    begin
      fields_to_fix = ProductTranslationRepairService::FIELDS_TO_FIX
      last_id = task.payload['last_id']
      
      # Ищем продукты, где хотя бы в одном из полей есть "translatedText"
      query_parts = fields_to_fix.map { |f| "#{f} LIKE '%translatedText%'" }

      products = Product.where(query_parts.join(" OR "))
      products = products.where("id > ?", last_id) if last_id

      # find_each игнорирует limit на отношении, поэтому считаем вручную
      processed_count = 0

      total_count = products.count
      Rails.logger.info "Starting RepairProductTranslationsJob for #{total_count} products (starting from ID: #{last_id || 'begin'})..."

      # Используем пул соединений для параллельной обработки
      products.find_in_batches(batch_size: 3) do |batch|
        break if limit && processed_count >= limit

        promises = batch.map do |product|
          Concurrent::Promises.future(product) do |p|
            ActiveRecord::Base.connection_pool.with_connection do
              ProductTranslationRepairService.repair_product(p)
            rescue => e
              Rails.logger.error "Error fixing translations for product #{p.sku}: #{e.message}"
              :error
            end
          end
        end

        results = Concurrent::Promises.zip(*promises).value!

        results.each do |res|
          if res == :error
            stats[:errors] += 1
            task.increment_errors!
          elsif res[:fixed]
            stats[:fixed] += 1
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
