# frozen_string_literal: true

class RecoverMissingWeightsJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 50
  THREADS_COUNT = 2

  def perform(limit: nil, task_id: nil, only_missing_weight: true)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("recover_missing_weights", limit: limit)
    
    # Сбрасываем счетчики если задача перезапускается
    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == 'pending'

    stats = {
      processed: 0,
      updated: 0,
      skipped: 0,
      errors: 0
    }

    started_at = Time.current

    begin
      check_task_not_stopped!(task)
      task.mark_as_running!
      
      query =
        if only_missing_weight
          Product.where(weight: nil)
        else
          Product.all
        end
      query = query.limit(limit) if limit.present?

      total_count = query.count
      task.update_payload!(total_to_process: total_count, only_missing_weight: only_missing_weight)

      notify_started("recover_missing_weights", limit: total_count)
      scope_note = only_missing_weight ? "without weight (NULL)" : "all products"
      Rails.logger.info "RecoverMissingWeightsJob: Starting #{total_count} products (#{scope_note})"

      # Обрабатываем пачками по BATCH_SIZE
      query.find_in_batches(batch_size: BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)
        Rails.logger.info "[WeightRecoveryJob] Processing batch of #{batch.size} products..."

        # Разделяем пачку на потоки
        threads = []
        # Группируем продукты для потоков
        batch.each_slice((batch.size.to_f / THREADS_COUNT).ceil) do |slice|
          threads << Thread.new(slice) do |product_slice|
            # Внутри потока нужно новое соединение с БД для ActiveRecord
            ActiveRecord::Base.connection_pool.with_connection do
              product_slice.each do |product|
                begin
                  result = Products::WeightRecoveryService.call(product)
                  
                  if result[:status] == :success
                    stats[:updated] += 1
                    task.increment_updated!
                  elsif result[:status] == :not_found
                    stats[:skipped] += 1
                  else
                    stats[:errors] += 1
                    task.increment_errors!
                    Rails.logger.error "[WeightRecoveryJob] Error for #{product.sku}: #{result[:message]}"
                  end
                  
                  stats[:processed] += 1
                  task.increment_processed!
                rescue StandardError => e
                  Rails.logger.error "[WeightRecoveryJob] CRITICAL ERROR for SKU #{product.sku}: #{e.class} - #{e.message}"
                  Rails.logger.error e.backtrace.first(10).join("\n")
                  stats[:errors] += 1
                  task.increment_errors!
                end
              end
            end
          end
        end

        threads.each(&:join)
        Rails.logger.info "[WeightRecoveryJob] Batch completed. Total processed: #{stats[:processed]}"
      end

      stats[:duration] = Time.current - started_at
      task.mark_as_completed!(stats)
      notify_completed("recover_missing_weights", stats)
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        Rails.logger.info("RecoverMissingWeightsJob: task #{task.id} was stopped manually")
        return
      end

      Rails.logger.error("RecoverMissingWeightsJob fatal error: #{e.class} - #{e.message}")
      task.mark_as_failed!(e.message)
      notify_error("recover_missing_weights", e)
      raise
    end
  end

  private
end
