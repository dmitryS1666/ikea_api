# frozen_string_literal: true

# Актуализация одной категории: список SKU с витрины PL (CategoryLtListingService + CategoryProductsFetcher),
# синхронизация с БД через ParseProductsJob#process_product, затем расширенные поля и варианты, дозагрузка связанных SKU.
#
# Сверка с витриной:
#   — каждый SKU из списка сайта проходит process_product + ExtendedAttributesFetchService (актуализация полей);
#   — опционально JSONL со строками формата results (ключ "Подробная информация о товаре") в payload.lt_jsonl_path —
#     тогда расширенные атрибуты и ВГХ берутся из этой строки (приоритет LT), цена/остаток — с PL;
#   — detach_orphans (по умолчанию true): убрать из категории связи CategoryProduct для SKU, которых нет в текущем списке витрины PL;
#     при false — оставить старые связи (отладка). Пустой listing_skus после обхода — отцепление не выполняется.
#
# Атрибуты (см. Products::ExtendedAttributesFetchService):
#   LT / JSONL: имя, подзаголовок, описания, характеристики, ВГХ, изображения, документы (по данным строки/PIP LT);
#   PL: цена, quantity (API / HTML PL), наборы/связи, документы при отсутствии на LT.
#
# Параллельность: 2 потока (Mutex + connection_pool.with_connection на поток).
class RefreshCategoryFromLtJob < ApplicationJob
  queue_as :parser

  THREADS = 2

  def perform(ikea_id:, task_id: nil, max_created: nil)
    task =
      if task_id.present?
        ParserTask.find(task_id)
      else
        create_parser_task("refresh_category_lt", limit: nil)
      end

    payload = (task.payload || {}).stringify_keys
    ikea_id = payload["ikea_id"].presence || ikea_id.to_s
    lt_jsonl_path = payload["lt_jsonl_path"].presence
    detach_orphans =
      if payload.key?("detach_orphans")
        v = ActiveModel::Type::Boolean.new.cast(payload["detach_orphans"])
        v.nil? ? true : v
      else
        true
      end
    include_referenced = ActiveModel::Type::Boolean.new.cast(payload["include_referenced"])
    max_created =
      if max_created.present?
        max_created.to_i
      elsif payload["max_created"].present?
        payload["max_created"].to_i
      else
        nil
      end
    max_created = nil if max_created.present? && max_created <= 0

    category = Category.find_by(ikea_id: ikea_id.to_s)
    unless category
      Rails.logger.error "RefreshCategoryFromLtJob: category not found for ikea_id=#{ikea_id}"
      return
    end
    check_task_not_stopped!(task)
    task.mark_as_running!

    notify_started("refresh_category_lt", limit: nil)
    started = Time.current

    unless CategoryLtListingService.pl_listing_url(category)
      msg = "Нет URL категории (или нечисловой ikea_id) — невозможно построить адрес витрины PL"
      task.mark_as_failed!(msg)
      notify_error("refresh_category_lt", StandardError.new(msg))
      return
    end

    rows_by_sku = load_lt_jsonl_index(lt_jsonl_path)
    if lt_jsonl_path.present? && rows_by_sku.empty?
      Rails.logger.warn "RefreshCategoryFromLtJob: lt_jsonl_path=#{lt_jsonl_path} — файл не прочитан или пуст, продолжаем без JSONL"
    end

    stats = { processed: 0, created: 0, updated: 0, errors: 0, detached: 0, linked: 0, created_skus: [] }
    stats_mutex = Mutex.new
    parser = ParseProductsJob.new
    listing_skus = []
    stop_listing = false

    begin
      offset = 0
      page_size = 50
      touched_skus = []

      loop do
        check_task_not_stopped!(task)
        break if stop_listing

        products_data = CategoryLtListingService.fetch_page(category, offset: offset, limit: page_size)
        break if products_data.empty?

        page_ids = products_data.filter_map do |pd|
          (pd["id"] || pd[:id] || pd["sku"] || pd[:sku]).to_s.presence
        end.uniq
        listing_skus.concat(page_ids)

        item_nos =
          products_data.map do |pd|
            pd["itemNoGlobal"] || pd[:itemNoGlobal] ||
              pd["itemNo"] || pd[:itemNo] ||
              pd["item_no"] || pd[:item_no] ||
              pd.dig("gprDescription", "itemNo")
          end.compact.uniq

        availability_data =
          if item_nos.any?
            begin
              IkeaApiService.check_availability(item_nos)
            rescue StandardError => e
              Rails.logger.error "RefreshCategoryFromLtJob: availability batch failed: #{e.message}"
              {}
            end
          else
            {}
          end

        page_skus =
          if max_created.present?
            process_listing_sequential(
              products_data, parser, category, availability_data, task, stats, max_created
            )
          else
            parallel_each(products_data, threads: THREADS) do |product_data|
              process_one_listing_item(product_data, parser, category, availability_data, task, stats, stats_mutex)
            end
          end
        touched_skus.concat(page_skus)

        stop_listing = true if max_created.present? && stats[:created] >= max_created

        offset += page_size
        break if products_data.length < page_size
      end

      touched_skus.uniq!
      listing_skus.uniq!
      stats[:linked] = ensure_category_links_for_listing!(category, listing_skus)

      parallel_each(touched_skus, threads: THREADS) do |sku|
        check_task_not_stopped!(task)

        product = Product.find_by(sku: sku)
        next unless product

        begin
          row = rows_by_sku[sku.to_s]
          ext = Products::ExtendedAttributesFetchService.fetch_for_product(product, results_jsonl_row: row)
          stats_mutex.synchronize { stats[:updated] += 1 if ext[:updated] }

          vres = IkeaLvProductVariantsService.new(product: product, force: false).call
          stats_mutex.synchronize { stats[:updated] += 1 if vres[:changed] }

          # По умолчанию не расширяем категорию связанными SKU, чтобы не тянуть "мусор".
          # Включается только явно через payload.include_referenced = true.
          if include_referenced
            Products::ReferencedProductsEnsureService.ensure_for!(product, category: category)
          end
        rescue StandardError => e
          Rails.logger.error "RefreshCategoryFromLtJob: enrich #{sku}: #{e.message}"
          stats_mutex.synchronize do
            stats[:errors] += 1
            task.increment_errors!
          end
        end
        nil
      end

      if detach_orphans && listing_skus.any?
        stats[:detached] = detach_category_products_not_in_listing(category, listing_skus)
      end

      stats[:duration] = Time.current - started
      task.update_payload!("created_skus" => stats[:created_skus]) if stats[:created_skus].present?
      task.mark_as_completed!(stats)
      notify_completed("refresh_category_lt", stats)
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        Rails.logger.info "RefreshCategoryFromLtJob: task #{task.id} stopped manually"
        return
      end

      Rails.logger.error "RefreshCategoryFromLtJob: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error("refresh_category_lt", e)
    end
  end

  private

  def process_listing_sequential(products_data, parser, category, availability_data, task, stats, max_created)
    page_skus = []
    products_data.each do |product_data|
      sku = process_one_listing_item(product_data, parser, category, availability_data, task, stats, nil)
      page_skus << sku if sku.present?
      break if stats[:created] >= max_created
    end
    page_skus
  end

  def process_one_listing_item(product_data, parser, category, availability_data, task, stats, mutex)
    check_task_not_stopped!(task)

    sku = product_data["id"] || product_data[:id] || product_data["sku"] || product_data[:sku]
    sku = sku.to_s

    begin
      res = parser.send(:process_product, product_data, category, availability_data)
      apply_listing_stats(res, sku, task, stats, mutex)
      sku.presence
    rescue StandardError => e
      Rails.logger.error "RefreshCategoryFromLtJob: product error #{e.message}"
      if mutex
        mutex.synchronize do
          stats[:errors] += 1
          task.increment_errors!
        end
      else
        stats[:errors] += 1
        task.increment_errors!
      end
      nil
    end
  end

  def apply_listing_stats(res, sku, task, stats, mutex)
    block = lambda do
      stats[:created] += 1 if res[:created]
      stats[:created_skus] << sku if res[:created] && sku.present?
      stats[:updated] += 1 if res[:updated]
      stats[:processed] += 1
      task.increment_processed!
    end

    if mutex
      mutex.synchronize(&block)
    else
      block.call
    end
  end

  def load_lt_jsonl_index(path)
    return {} if path.blank?

    path = path.to_s.strip
    return {} unless File.file?(path) && File.readable?(path)

    idx = {}
    File.foreach(path, chomp: true) do |line|
      next if line.blank?
      row = JSON.parse(line)
      sku = row["sku"] || row[:sku]
      idx[sku.to_s] = row if sku.present?
    rescue JSON::ParserError => e
      Rails.logger.warn "RefreshCategoryFromLtJob: пропуск строки JSONL: #{e.message}"
    end
    idx
  end

  def detach_category_products_not_in_listing(category, listing_skus)
    skus = listing_skus.map(&:to_s).uniq
    return 0 if skus.empty?

    rel = CategoryProduct.joins(:product).where(category_id: category.ikea_id).where.not(products: { sku: skus })
    n = rel.count
    rel.delete_all
    n
  end

  # Гарантирует связь Product <-> Category для всех SKU, полученных из листинга категории.
  # Это нужно даже когда продукт уже был в БД до запуска джобы.
  def ensure_category_links_for_listing!(category, listing_skus)
    skus = listing_skus.map(&:to_s).uniq
    return 0 if skus.empty?

    created_links = 0
    Product.where(sku: skus).find_each(batch_size: 500) do |product|
      cp = CategoryProduct.find_or_create_by!(product: product, category_id: category.ikea_id)
      created_links += 1 if cp.previously_new_record?
    end
    created_links
  rescue StandardError => e
    Rails.logger.error "RefreshCategoryFromLtJob: ensure links failed for category=#{category.ikea_id}: #{e.message}"
    0
  end

  def parallel_each(collection, threads: THREADS)
    return [] if collection.blank?

    n = [threads, collection.size].min
    chunk_size = (collection.size / n.to_f).ceil
    chunks = collection.each_slice(chunk_size).to_a
    results = []
    mutex = Mutex.new

    threads_list =
      chunks.reject(&:empty?).map do |chunk|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            part = chunk.filter_map { |item| yield(item) }
            mutex.synchronize { results.concat(part) }
          end
        end
      end

    threads_list.each(&:join)
    results
  end
end
