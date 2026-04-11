# frozen_string_literal: true

# Актуализация одной категории по ikea_id (витрина PL → БД).
#
# Пайплайн:
#   1) Найти Category по ikea_id, проверить URL витрины PL.
#   2) Постранично забрать SKU с листинга; для каждой строки ParseProductsJob#process_product
#      (сопоставление с БД через Products::ListingSkuResolver — s12345678 vs 12345678).
#   3) Отцепить от категории товары, которых нет в актуальном списке (CategoryProduct), без удаления Product.
#   4) Для каждого затронутого SKU: PL+LT — ExtendedAttributesFetchService (цена, qty, картинки URL,
#      related_products, included_products, вес/размеры/описание/материалы/документы с LT и PL).
#      Затем IkeaLvProductVariantsService (force: true) — варианты с PIP PL.
#      Затем ImageDownloader.sync_product_images — локальные WebP при наличии remote images.
#   5) Опционально: lt_jsonl_path в payload — строки JSONL по SKU (и алиасам) для приоритета LT;
#      include_referenced — дозагрузка связанных SKU в категорию.
#
# Контракт API с фронтом не меняется: те же поля ProductSerializer, типы и структура variants.
#
# Параллельность: 2 потока (Mutex + connection_pool.with_connection).
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

    stats = {
      processed: 0,
      created: 0,
      updated: 0,
      errors: 0,
      detached: 0,
      linked: 0,
      images_synced: 0,
      created_skus: []
    }
    stats_mutex = Mutex.new
    parser = ParseProductsJob.new
    canonical_listing_skus = []
    stop_listing = false

    begin
      offset = 0
      page_size = 50
      touched_canonical_skus = []

      loop do
        check_task_not_stopped!(task)
        break if stop_listing

        products_data = CategoryLtListingService.fetch_page(category, offset: offset, limit: page_size)
        break if products_data.empty?

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

        page_canonical =
          if max_created.present?
            process_listing_sequential(
              products_data, parser, category, availability_data, task, stats, max_created
            )
          else
            parallel_each(products_data, threads: THREADS) do |product_data|
              process_one_listing_item(product_data, parser, category, availability_data, task, stats, stats_mutex)
            end
          end
        touched_canonical_skus.concat(page_canonical)

        stop_listing = true if max_created.present? && stats[:created] >= max_created

        offset += page_size
        break if products_data.length < page_size
      end

      touched_canonical_skus.compact!
      touched_canonical_skus.uniq!
      canonical_listing_skus.replace(touched_canonical_skus)

      stats[:linked] = ensure_category_links_for_listing!(category, canonical_listing_skus)

      enrich_products!(
        canonical_listing_skus,
        category,
        rows_by_sku,
        include_referenced,
        task,
        stats,
        stats_mutex
      )

      if detach_orphans && canonical_listing_skus.any?
        stats[:detached] = detach_category_products_not_in_listing(category, canonical_listing_skus)
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

  def enrich_products!(canonical_skus, category, rows_by_sku, include_referenced, task, stats, stats_mutex)
    parallel_each(canonical_skus, threads: THREADS) do |sku|
      check_task_not_stopped!(task)

      product = Product.find_by(sku: sku)
      next unless product

      begin
        row = jsonl_row_for_product(rows_by_sku, product.sku)
        ext = Products::ExtendedAttributesFetchService.fetch_for_product(product, results_jsonl_row: row)
        stats_mutex.synchronize { stats[:updated] += 1 if ext[:updated] }

        vres = IkeaLvProductVariantsService.new(product: product, force: true).call
        stats_mutex.synchronize { stats[:updated] += 1 if vres[:changed] }

        sync_local_images!(product, stats, stats_mutex)

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
  end

  def jsonl_row_for_product(rows_by_sku, sku)
    Products::ListingSkuResolver.aliases(sku).each do |key|
      row = rows_by_sku[key.to_s]
      return row if row.present?
    end
    nil
  end

  def sync_local_images!(product, stats, stats_mutex)
    return if Array(product.images).compact.reject(&:blank?).empty?

    result = ImageDownloader.sync_product_images(product)
    return unless result[:changed]

    stats_mutex.synchronize { stats[:images_synced] += 1 }
  rescue StandardError => e
    Rails.logger.warn "RefreshCategoryFromLtJob: images sku=#{product.sku}: #{e.message}"
  end

  def process_listing_sequential(products_data, parser, category, availability_data, task, stats, max_created)
    page_skus = []
    products_data.each do |product_data|
      canon = process_one_listing_item(product_data, parser, category, availability_data, task, stats, nil)
      page_skus << canon if canon.present?
      break if stats[:created] >= max_created
    end
    page_skus
  end

  def process_one_listing_item(product_data, parser, category, availability_data, task, stats, mutex)
    check_task_not_stopped!(task)

    begin
      res = parser.send(:process_product, product_data, category, availability_data)
      if res[:created] || res[:updated]
        apply_listing_stats(res, task, stats, mutex)
      end
      res[:sku].presence
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

  def apply_listing_stats(res, task, stats, mutex)
    block = lambda do
      stats[:created] += 1 if res[:created]
      stats[:created_skus] << res[:sku] if res[:created] && res[:sku].present?
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
      next if sku.blank?

      Products::ListingSkuResolver.aliases(sku.to_s).each do |key|
        idx[key.to_s] = row
      end
    rescue JSON::ParserError => e
      Rails.logger.warn "RefreshCategoryFromLtJob: пропуск строки JSONL: #{e.message}"
    end
    idx
  end

  def detach_category_products_not_in_listing(category, canonical_skus)
    skus = canonical_skus.map(&:to_s).uniq
    return 0 if skus.empty?

    rel = CategoryProduct.joins(:product).where(category_id: category.ikea_id).where.not(products: { sku: skus })
    n = rel.count
    rel.delete_all
    n
  end

  def ensure_category_links_for_listing!(category, canonical_skus)
    skus = canonical_skus.map(&:to_s).uniq
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
