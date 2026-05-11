# frozen_string_literal: true

# По SKU: только цена и количество с польского сайта + актуализация URL товара (Products::PlPriceStockRefreshService).
# Без IkeaApiService и без прочих полей. По умолчанию 2 потока (параметр threads).
# Опционально +sku: или payload задачи с ключом "sku" — обработка только строк с этим артикулом в БД.
class RefreshPlPricesAndStockJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 40
  THREADS_DEFAULT = 2
  THREADS_MAX = 5

  # Список значений products.sku для поиска (в т.ч. 19485139 / s19485139 / 194.851.39).
  def self.pl_price_stock_lookup_skus(raw)
    c = Products::ListingSkuResolver.coerce_listing_identifier(raw)&.strip
    return [] if c.blank?

    digits = c.gsub(/\D/, "")
    key = digits.match?(/\A\d{8}\z/) ? digits : c
    Products::ListingSkuResolver.aliases(key).uniq
  end

  def self.products_relation_for_pl_refresh(sku_raw)
    base = Product.where.not(sku: [nil, ""])
    skus = pl_price_stock_lookup_skus(sku_raw)
    return base if skus.blank?

    base.where(sku: skus)
  end

  def perform(task_id: nil, threads: THREADS_DEFAULT, sku: nil, **_options)
    initial_payload = {}
    initial_payload["sku"] = sku.to_s.strip if sku.present?

    task =
      if task_id
        ParserTask.find(task_id)
      else
        create_parser_task("pl_prices_stock", limit: nil, payload: initial_payload)
      end

    check_task_not_stopped!(task)
    task.mark_as_running!

    threads_count = [[threads.to_i, 1].max, THREADS_MAX].min

    resolved_sku = sku.to_s.strip.presence ||
      task.payload&.dig("sku").presence ||
      task.payload&.dig(:sku)&.to_s&.strip&.presence
    products_scope = self.class.products_relation_for_pl_refresh(resolved_sku)

    if resolved_sku.present? && !products_scope.exists?
      msg = "Товар с SKU «#{resolved_sku}» не найден в базе (проверьте формат: 8 цифр или s + 8 цифр)."
      Rails.logger.warn "RefreshPlPricesAndStockJob: #{msg}"
      task.mark_as_failed!(msg)
      notify_error("pl_prices_stock", StandardError.new(msg))
      return
    end

    notify_started(
      "pl_prices_stock",
      limit: resolved_sku.present? ? "только SKU #{resolved_sku}" : nil
    )
    started = Time.current
    stats = { processed: 0, updated: 0, errors: 0 }

    begin
      products_scope.find_in_batches(batch_size: BATCH_SIZE) do |batch|
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
