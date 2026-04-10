# frozen_string_literal: true

class UpdateAllProductImagesJob < ApplicationJob
  queue_as :parser

  BATCH_SIZE = 100
  THREADS_COUNT = 2

  def perform(task_id: nil, limit: nil, force: true, images_limit: nil, reset: false, cleanup: true, sku: nil, threads: 2, image_contains: nil, category_ikea_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("update_all_product_images", limit: limit)
    payload_h = task.payload.is_a?(Hash) ? task.payload.stringify_keys : {}

    # Сброс прогресса, если заказано
    if reset
      task.update_payload!("last_id" => nil)
      task.update!(processed: 0, updated: 0, error_count: 0)
      payload_h = task.reload.payload.is_a?(Hash) ? task.payload.stringify_keys : {}
    end

    # Резюмирование
    last_id = payload_h["last_id"]

    # Извлекаем SKU из аргументов или из payload задачи
    skus_from_payload = payload_h["skus"]
    sku ||= skus_from_payload if skus_from_payload.present?

    image_contains ||= payload_h["image_contains"]
    image_contains = image_contains.to_s.strip.presence if image_contains.present?

    category_ikea_id ||= payload_h["category_ikea_id"]
    category_ikea_id = category_ikea_id.to_s.strip.presence if category_ikea_id.present?

    if images_limit.blank?
      il = payload_h["images_limit"]
      images_limit = il.present? && il.to_i.positive? ? il.to_i : nil
    else
      images_limit = images_limit.to_i
      images_limit = nil unless images_limit.positive?
    end
    
    # Если передано несколько SKU через строку/массив, обрабатываем их все
    target_skus = []
    if sku.present?
      target_skus = sku.is_a?(Array) ? sku : sku.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?)
      target_skus = target_skus.map { |s| s.gsub(".", "") }.uniq
    end

    # Динамическое количество потоков из параметров
    threads_count = [threads.to_i, 1].max
    threads_count = [threads_count, 10].min # Ограничение сверху

    stats = {
      processed: task.processed || 0,
      updated: task.updated || 0,
      errors: task.error_count || 0,
      total_to_process: 0
    }

    log_file = Rails.root.join("log", "update_all_product_images_#{task.id}.log")
    logger = Logger.new(log_file)
    logger.info "Starting UpdateAllProductImagesJob (task_id: #{task.id}, skus: #{target_skus.join(',')}, category_ikea_id: #{category_ikea_id.inspect}, image_contains: #{image_contains.inspect}, images_limit: #{images_limit.inspect}, threads: #{threads_count}, last_id: #{last_id}, limit: #{limit}, force: #{force}, cleanup: #{cleanup}, category_scope_full: #{target_skus.empty? && category_ikea_id.present?})"

    started_at = Time.current
    task.mark_as_running!

    begin
      # Собираем ID товаров для обработки.
      # Без SKU: глобально — только jpg/jpeg/png в local_images (уже .webp в БД не трогаем).
      # С указанной категорией — ещё и товары с URL в images без нормальных локальных webp (дозагрузка + конвертация).
      query = Product.order(:id)

      if target_skus.any?
        query = query.where(sku: target_skus)
        query = query.merge(Product.in_category_ikea_id(category_ikea_id)) if category_ikea_id.present?
      elsif category_ikea_id.present?
        query = query.merge(Product.in_category_ikea_id(category_ikea_id))
        query = query.merge(Product.needing_product_image_job_processing)
        query = query.where("products.id > ?", last_id) if last_id.present?
        query = query.limit(limit) if limit.present?
      else
        query = query.merge(Product.with_raster_local_images)
        query = query.where("products.id > ?", last_id) if last_id.present?
        query = query.limit(limit) if limit.present?
      end

      query = query.merge(Product.with_image_json_containing(image_contains)) if image_contains.present?

      total_to_process_count = query.count
      stats[:total_to_process] = total_to_process_count
      logger.info "Products remaining to process: #{total_to_process_count}"

      if target_skus.empty? && last_id.present? && total_to_process_count.zero?
        still_scope =
          if category_ikea_id.present?
            Product.in_category_ikea_id(category_ikea_id).merge(Product.needing_product_image_job_processing)
          else
            Product.with_raster_local_images
          end
        still_scope = still_scope.merge(Product.with_image_json_containing(image_contains)) if image_contains.present?
        if still_scope.where("products.id <= ?", last_id).exists?
          logger.warn "UpdateAllProductImagesJob: остались товары для обработки при id <= last_id (#{last_id}); " \
                      "для прохода по ним включите «Сбросить прогресс» в задаче."
        end
      end

      query.find_in_batches(batch_size: BATCH_SIZE) do |batch|
        check_task_not_stopped!(task)

        # Обработка пачки в несколько потоков
        threads_list = []
        batch.each_slice((batch.size / threads_count.to_f).ceil) do |slice|
          threads_list << Thread.new(slice, task.id) do |items, t_id|
            # КРИТИЧЕСКИ ВАЖНО: Сразу освобождаем соединение, которое поток мог унаследовать
            ActiveRecord::Base.connection_pool.release_connection

            items.each do |product|
              begin
                # Проверяем остановку задачи
                if ParserTask.where(id: t_id, status: 'failed').where("error_message LIKE ?", "%Остановлено вручную%").exists?
                  break
                end

                # Основная работа (сеть + CPU) - БЕЗ удержания коннекта
                result = nil
                ActiveRecord::Base.connection_pool.with_connection do
                  # Берем коннект только чтобы инициализировать сервис (если он лезет в БД сразу)
                  # Но IkeaLvImageRecoveryService.new обычно не лезет.
                  # Однако, вызов .call внутри может неявно брать коннект.
                end

                # Выполняем тяжелую работу ВНЕ with_connection
                result = IkeaLvImageRecoveryService.new(
                  product: product,
                  images_limit: images_limit,
                  force: force
                ).call

                # Берем соединение только для записи результата
                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_updated! if result[:changed]
                  thread_task.increment_processed!
                  logger.info "[SUCCESS] SKU: #{product.sku} (ID: #{product.id})"
                end
              rescue StandardError => e
                ActiveRecord::Base.connection_pool.with_connection do
                  thread_task = ParserTask.find(t_id)
                  thread_task.increment_errors!
                  thread_task.increment_processed!
                end
                logger.error "[ERROR] SKU: #{product.sku}: #{e.message}"
              ensure
                # На всякий случай еще раз освобождаем после каждой итерации
                ActiveRecord::Base.connection_pool.release_connection
              end
            end
          end
        end

        threads_list.each(&:join)
        
        # Сохраняем прогресс после каждой пачки
        last_processed_id = batch.last.id
        task.update_payload!("last_id" => last_processed_id)
        
        # Проверка лимита
        if limit && task.reload.processed >= limit
          logger.info "Reached limit of #{limit} products. Finishing."
          break
        end
      end

      stats[:duration] = Time.current - started_at
      task.reload
      stats[:processed] = task.processed
      stats[:updated] = task.updated
      stats[:errors] = task.error_count
      
      task.mark_as_completed!(stats)
      notify_completed("update_all_product_images", stats)
      logger.info "Job finished. Stats: #{stats.inspect}"
    rescue StandardError => e
      if e.message == 'Task was stopped manually'
        logger.info "Job was stopped manually."
        return
      end

      logger.fatal "Fatal error in job: #{e.class}: #{e.message}"
      logger.fatal e.backtrace.join("\n")
      
      task.mark_as_failed!(e.message)
      notify_error("update_all_product_images", e)
      raise e
    end
  end

  private

  def run_garbage_collector(logger)
    logger.info "Starting Garbage Collection for image storage..."
    
    # Собираем все ссылки на картинки из БД
    referenced_paths = Set.new
    Product.find_each(batch_size: 500) do |product|
      begin
        images = product.local_images
        images = JSON.parse(images) if images.is_a?(String)
        Array(images).compact.each { |path| referenced_paths << path.to_s.sub(/\A\//, "") }
      rescue JSON::ParserError
        next
      end
    end

    logger.info "Total referenced images in DB: #{referenced_paths.size}"

    # Сканируем хранилище
    storage_root = Rails.root.join("public", "images", "products")
    unless Dir.exist?(storage_root)
      logger.info "Storage root does not exist, skipping cleanup."
      return
    end

    deleted_count = 0
    Dir.glob(storage_root.join("**", "*")).each do |file_path|
      next unless File.file?(file_path)
      
      relative_path = file_path.sub(Rails.root.join("public/").to_s, "")
      unless referenced_paths.include?(relative_path)
        File.delete(file_path)
        deleted_count += 1
      end
    end

    # Удаляем пустые директории
    system("find #{storage_root} -type d -empty -delete")

    logger.info "Garbage Collection complete. Deleted #{deleted_count} orphaned files."
  end
end
