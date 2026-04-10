# frozen_string_literal: true

# По SKU: только цена и количество с польского сайта + актуализация URL товара (Products::PlPriceStockRefreshService).
# Без IkeaApiService и без прочих полей. По умолчанию 2 потока (параметр threads).
class RefreshPlPricesAndStockJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 40
  THREADS_DEFAULT = 2
  THREADS_MAX = 5

  def perform(task_id: nil, threads: THREADS_DEFAULT, **_options)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("pl_prices_stock", limit: nil)
    check_task_not_stopped!(task)
    task.mark_as_running!

    threads_count = [[threads.to_i, 1].max, THREADS_MAX].min

    notify_started("pl_prices_stock", limit: nil)
    started = Time.current
    stats = { processed: 0, updated: 0, errors: 0 }

    begin
      Product.where.not(sku: [nil, ""]).find_in_batches(batch_size: BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)

        threads_list = []
        batch.each_slice((batch.size / threads_count.to_f).ceil) do |slice|
          threads_list << Thread.new(slice, task.id) do |items, t_id|
            ActiveRecord::Base.connection_pool.release_connection

            items.each do |product|
              begin
                if ParserTask.where(id: t_id, status: "failed").where("error_message LIKE ?", "%Остановлено вручную%").exists?
                  break
                end

                r = Products::PlPriceStockRefreshService.refresh!(product)

                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_processed!
                  thread_task.increment_updated! if r[:updated]
                end
              rescue StandardError => e
                Rails.logger.error "RefreshPlPricesAndStockJob: #{product.sku}: #{e.message}"
                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_errors!
                  thread_task.increment_processed!
                end
              ensure
                ActiveRecord::Base.connection_pool.release_connection
              end
            end
          end
        end

        threads_list.each(&:join)
      end

      stats[:duration] = Time.current - started
      stats[:processed] = task.reload.processed
      stats[:updated] = task.updated
      stats[:errors] = task.error_count
      task.mark_as_completed!(stats)
      notify_completed("pl_prices_stock", stats)
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        Rails.logger.info "RefreshPlPricesAndStockJob: task #{task.id} stopped manually"
        return
      end

      Rails.logger.error "RefreshPlPricesAndStockJob: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error("pl_prices_stock", e)
    end
  end
end
