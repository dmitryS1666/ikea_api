# frozen_string_literal: true

class UpdateProductVariantsJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 50
  THREADS_COUNT = 2

  def perform(task_id: nil, limit: nil, force: false, sku: nil, threads: 2, **_options)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("update_product_variants", limit: limit)
    
    # Резюмирование
    last_id = task.payload.is_a?(Hash) ? task.payload["last_id"] : nil
    
    target_skus = []
    if sku.present?
      target_skus = sku.is_a?(Array) ? sku : sku.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?)
      target_skus = target_skus.map { |s| s.gsub(".", "") }.uniq
    end

    threads_count = [threads.to_i, 1].max
    threads_count = [threads_count, 5].min # Ограничиваем для вариантов, так как они могут обновлять несколько записей

    log_file = Rails.root.join("log", "update_product_variants_#{task.id}.log")
    logger = Logger.new(log_file)
    logger.info "Starting UpdateProductVariantsJob (task_id: #{task.id}, skus: #{target_skus.join(',')}, threads: #{threads_count}, last_id: #{last_id}, limit: #{limit}, force: #{force})"

    started_at = Time.current
    task.mark_as_running!

    begin
      # Собираем ID товаров для обработки
      # ТЗ: "для всех продуктов где это поле [variants] есть и тех продуктов, которые есть у других variants но сами не имеют variants"
      
      if target_skus.any?
        query = Product.where(sku: target_skus)
      else
        # Продукты, у которых variants не пустой
        # Или продукты, которые упоминаются в variants других продуктов (это сложнее найти одним запросом, 
        # но мы можем начать с тех у кого variants не пустой, а они в процессе обновят своих собратьев)
        query = Product.where("variants IS NOT NULL AND variants != '[]'")
        query = query.where('id > ?', last_id) if last_id.present?
        query = query.limit(limit) if limit.present?
      end

      logger.info "Products remaining to process: #{query.count}"

      query.find_in_batches(batch_size: BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)

        threads_list = []
        batch.each_slice((batch.size / threads_count.to_f).ceil) do |slice|
          threads_list << Thread.new(slice, task.id) do |items, t_id|
            ActiveRecord::Base.connection_pool.release_connection

            items.each do |product|
              begin
                if ParserTask.where(id: t_id, status: 'failed').where("error_message LIKE ?", "%Остановлено вручную%").exists?
                  break
                end

                result = IkeaLvProductVariantsService.new(
                  product: product,
                  force: force
                ).call

                product.reload
                cat = product.category || product.categories.first
                if cat.present? && product.variants_payload.present?
                  Products::VariantProductsEnsureService.ensure!(product, category: cat)
                end

                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_updated! if result[:changed]
                  thread_task.increment_processed!
                  logger.info "[SUCCESS] SKU: #{product.sku} (ID: #{product.id}) - Changed: #{result[:changed]}, Type: #{result[:type]}, Count: #{result[:count]}"
                end
              rescue StandardError => e
                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_errors!
                  thread_task.increment_processed!
                end
                logger.error "[ERROR] SKU: #{product.sku}: #{e.message}"
              ensure
                ActiveRecord::Base.connection_pool.release_connection
              end
            end
          end
        end

        threads_list.each(&:join)
        
        last_processed_id = batch.last.id
        task.update_payload!("last_id" => last_processed_id)
        
        if limit && task.reload.processed >= limit
          break
        end
      end

      stats = {
        duration: Time.current - started_at,
        processed: task.reload.processed,
        updated: task.updated,
        errors: task.error_count
      }
      
      task.mark_as_completed!(stats)
      notify_completed("update_product_variants", stats)
      logger.info "Job finished. Stats: #{stats.inspect}"
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        logger.info "Job was stopped manually."
        return
      end

      logger.fatal "Fatal error in job: #{e.class}: #{e.message}"
      logger.fatal e.backtrace.join("\n")
      
      task.mark_as_failed!(e.message)
      notify_error("update_product_variants", e)
      raise e
    end
  end

  private

  def create_parser_task(task_type, limit: nil)
    ParserTask.create!(
      task_type: task_type,
      status: 'pending',
      payload: { limit: limit },
      processed: 0,
      updated: 0,
      error_count: 0
    )
  end

  def check_task_not_stopped!(task)
    task.reload
    raise 'Task was stopped manually' if task.status == 'failed' && task.error_message.to_s.include?('Остановлено вручную')
  end

  def notify_completed(task_type, stats)
    TelegramService.send_parser_completed(task_type, stats)
  end

  def notify_error(task_type, error)
    TelegramService.send_parser_error(task_type, error)
  end
end
