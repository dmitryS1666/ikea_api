# frozen_string_literal: true

# Актуализация одной категории по ikea_id (витрина PL → БД).
#
# Пайплайн:
#   1) Найти Category по ikea_id, проверить URL витрины PL.
#   2) Постранично забрать SKU с листинга; для каждой строки ParseProductsJob#process_product
#      (сопоставление с БД через Products::ListingSkuResolver — s12345678 vs 12345678).
#   3) Отцепить от категории товары, которых нет в актуальном списке (CategoryProduct), без удаления Product.
#   4) Для каждого затронутого SKU: сначала SKU с листинга PL; LT — донор русских текстов (если страница LT есть),
#      иначе полная карточка с PL без обязательного OpenAI (fallback_pl_when_lt_missing). Цена/qty с PL.
#      included_products — только из модалки «Elementy w zestawie» на PL; отсутствующие позиции набора
#      догружаются IncludedProductsBootstrapService (без variants/related, без привязки к категории).
#      related_products — см. RelatedProductsCollection::ENABLED и process_related.
#      Затем IkeaLvProductVariantsService (force: true) — варианты с PIP PL.
#      Затем ImageDownloader.sync_product_images (после вариантов и ensure) — локальные WebP + зеркало в public/images.
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
    max_created =
      if max_created.present?
        max_created.to_i
      elsif payload["max_created"].present?
        payload["max_created"].to_i
      else
        nil
      end
    max_created = nil if max_created.present? && max_created <= 0
    process_related =
      if payload.key?("process_related")
        ActiveModel::Type::Boolean.new.cast(payload["process_related"])
      else
        false
      end

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
      created_skus: [],
      related_skus: [],
      missing_related_skus: []
    }
    parser = ParseProductsJob.new
    canonical_listing_skus = []

    begin
      offset = 0
      page_size = 50
      touched_canonical_skus = []

      # 1. Собираем все SKU основной категории с PL
      all_pl_products = []
      loop do
        check_task_not_stopped!(task)
        products_data = CategoryLtListingService.fetch_page(category, offset: offset, limit: page_size)
        break if products_data.empty?
        
        all_pl_products.concat(products_data)
        offset += page_size
        break if products_data.length < page_size
      end

      # 2. Обрабатываем каждый продукт
      all_pl_products.each do |product_data|
        check_task_not_stopped!(task)
        
        # Создаем/обновляем базовый продукт (цена и остатки с PL)
        canon = process_one_listing_item(product_data, parser, category, {}, task, stats, nil)
        next if canon.blank?

        # Один и тот же артикул в БД может быть как s12345678, так и 12345678 — find_by(sku: canon) иногда мимо.
        # В «канон» для отвязки и category_products кладём только реальный products.sku после резолва.
        product = Products::ListingSkuResolver.find_product(canon) || Product.find_by(sku: canon.to_s.strip)
        next unless product

        touched_canonical_skus << product.sku.to_s

        # 3. Обогащаем данными (LT -> PL + AI)
        # Внутри enrich_product! происходит:
        # - Проверка LT, если нет - AI перевод
        # - Variants (IkeaLvProductVariantsService)
        # - Related/Included (ReferencedProductsEnsureService)
        enrich_product!(product, category, rows_by_sku, task, stats, nil, process_related: process_related)
        
        break if max_created.present? && stats[:created] >= max_created
      end

      touched_canonical_skus.compact!
      touched_canonical_skus.uniq!
      canonical_listing_skus.replace(touched_canonical_skus)

      stats[:linked] = ensure_category_links_for_listing!(category, canonical_listing_skus)

      if detach_orphans && canonical_listing_skus.any?
        stats[:detached] = detach_category_products_not_in_listing(category, canonical_listing_skus)
      end

      stats[:duration] = Time.current - started
      stats[:related_skus] = stats[:related_skus].uniq.sort
      stats[:related_skus_count] = stats[:related_skus].size
      stats[:missing_related_skus] = stats[:missing_related_skus].uniq.sort
      stats[:missing_related_skus_count] = stats[:missing_related_skus].size
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

  def enrich_product!(product, category, rows_by_sku, task, stats, mutex, process_related: false)
    check_task_not_stopped!(task)

    begin
      row = jsonl_row_for_product(rows_by_sku, product.sku)
      # Принудительно используем ИИ-перевод, если нет на LT
      ext = Products::ExtendedAttributesFetchService.fetch_for_product(
        product,
        results_jsonl_row: row,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true
      )
      
      if mutex
        mutex.synchronize { stats[:updated] += 1 if ext[:updated] }
      else
        stats[:updated] += 1 if ext[:updated]
      end

      product.reload

      # Варианты (PIP PL): variants_payload с URL картинок по цветам/размерам
      vres = IkeaLvProductVariantsService.new(product: product, force: true).call
      if mutex
        mutex.synchronize { stats[:updated] += 1 if vres[:changed] }
      else
        stats[:updated] += 1 if vres[:changed]
      end

      product.reload

      if product.variants_payload.present?
        # Это создаст новые Product для вариантов и вызовет ExtendedAttributesFetchService для них
        Products::VariantProductsEnsureService.ensure!(product, category: category)
      end

      # В одном проходе контролируем качество вариантов: описания/материалы/картинки.
      ensure_variant_siblings_quality!(product, category, task, stats, mutex)

      # Позиции набора — после вариантов: иначе VariantProductsEnsureService повесил бы CategoryProduct на ту же строку.
      product.reload
      Products::IncludedProductsBootstrapService.ensure!(product)

      related_in_base, related_missing = collect_related_skus_for(product)
      persist_missing_related_skus!(product, related_missing)
      if mutex
        mutex.synchronize do
          stats[:related_skus].concat(related_in_base) if related_in_base.any?
          stats[:missing_related_skus].concat(related_missing) if related_missing.any?
        end
      else
        stats[:related_skus].concat(related_in_base) if related_in_base.any?
        stats[:missing_related_skus].concat(related_missing) if related_missing.any?
      end

      # Временно отключено: не подтягиваем/не создаём связи для related products из этой джобы.
      if process_related
        Products::ReferencedProductsEnsureService.ensure_for!(product, category: category)
      end

      # Локальные картинки — после финального состояния images / вариантов (как в EnrichVariantProductJob)
      product.reload
      sync_local_images!(product, stats, mutex)
      sync_variant_siblings_images!(product, stats, mutex)
    rescue StandardError => e
      Rails.logger.error "RefreshCategoryFromLtJob: enrich #{product.sku}: #{e.message}"
      if mutex
        mutex.synchronize do
          stats[:errors] += 1
          task.increment_errors!
        end
      else
        stats[:errors] += 1
        task.increment_errors!
      end
    end
  end

  def enrich_products!(canonical_skus, category, rows_by_sku, _include_referenced, task, stats, stats_mutex)
    parallel_each(canonical_skus, threads: THREADS) do |sku|
      product = Product.find_by(sku: sku)
      next unless product
      enrich_product!(product, category, rows_by_sku, task, stats, stats_mutex)
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

  def sync_local_images!(product, stats, mutex)
    return if Array(product.images).compact.reject(&:blank?).empty?

    result = ImageDownloader.sync_product_images(product)
    return unless result[:changed]

    if mutex
      mutex.synchronize { stats[:images_synced] += 1 }
    else
      stats[:images_synced] += 1
    end
  rescue StandardError => e
    Rails.logger.warn "RefreshCategoryFromLtJob: images sku=#{product.sku}: #{e.message}"
  end

  # Отдельные Product по SKU из variants / variants_payload — догружаем local_images (ActiveStorage + зеркало в public)
  def sync_variant_siblings_images!(parent, stats, mutex)
    skus = variant_skus_for(parent)
    return if skus.empty?

    skus.each do |vs|
      other = Products::ListingSkuResolver.find_product(vs) || Product.find_by(sku: vs)
      next unless other
      next if Array(other.images).compact.reject(&:blank?).empty?

      sync_local_images!(other, stats, mutex)
    end
  rescue StandardError => e
    Rails.logger.warn "RefreshCategoryFromLtJob: variant siblings images parent=#{parent.sku}: #{e.message}"
  end

  def ensure_variant_siblings_quality!(parent, category, task, stats, mutex)
    skus = variant_skus_for(parent)
    return if skus.empty?

    skus.each do |vs|
      other = Products::ListingSkuResolver.find_product(vs) || Product.find_by(sku: vs)
      next unless other

      ext = Products::ExtendedAttributesFetchService.fetch_for_product(
        other,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true
      )
      if ext[:updated]
        if mutex
          mutex.synchronize { stats[:updated] += 1 }
        else
          stats[:updated] += 1
        end
      end

      # Держим связи варианта с текущей категорией консистентными.
      CategoryProduct.find_or_create_by!(product: other, category_id: category.ikea_id.to_s)

      sync_local_images!(other, stats, mutex)
    rescue StandardError => e
      Rails.logger.warn "RefreshCategoryFromLtJob: variant quality sku=#{vs} parent=#{parent.sku}: #{e.message}"
      if mutex
        mutex.synchronize do
          stats[:errors] += 1
          task.increment_errors!
        end
      else
        stats[:errors] += 1
        task.increment_errors!
      end
    end
  end

  def variant_skus_for(parent)
    from_column = parent.normalized_variant_skus.map(&:to_s).map(&:strip).reject(&:blank?)
    from_payload = Products::VariantProductsEnsureService.variant_skus_from_variants_payload(parent.variants_payload)
    (from_column + from_payload).uniq - [parent.sku.to_s]
  end

  def collect_related_skus_for(parent)
    products = [parent]
    variant_skus_for(parent).each do |vs|
      p = Products::ListingSkuResolver.find_product(vs) || Product.find_by(sku: vs)
      products << p if p
    end

    normalized_articles =
      products
      .flat_map do |p|
        Array(p.related_products) +
          Array(p.included_products) +
          Array(p.set_items)
      end
      .map(&:to_s)
      .map { |s| s.gsub(/\D/, "") }
      .select { |s| s.match?(/\A\d{8}\z/) }
      .uniq

    existing, missing = normalized_articles.partition { |article| related_sku_exists_in_base?(article) }
    [existing, missing]
  end

  def related_sku_exists_in_base?(article)
    Product.exists?(item_no: article) ||
      Product.where("regexp_replace(upper(sku), '[^0-9A-Z]', '', 'g') = ?", article.upcase).exists?
  end

  def persist_missing_related_skus!(product, values)
    list = Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    attr_type = product.class.type_for_attribute("missing_related_skus").type
    payload = [:json, :jsonb].include?(attr_type) ? list : list.to_json
    product.update_column(:missing_related_skus, payload)
  rescue StandardError => e
    Rails.logger.warn "RefreshCategoryFromLtJob: save missing_related_skus sku=#{product.sku}: #{e.message}"
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
    cid = category.ikea_id.to_s
    skus = expanded_listing_skus_for_category_job(canonical_skus)
    return 0 if skus.empty?

    rel = CategoryProduct.joins(:product).where(category_id: cid).where.not(products: { sku: skus })
    n = rel.count
    rel.delete_all

    # Старые товары оставались в выборке @category.products (foreign_key category_id), хотя связь
    # category_products уже снята — из-за этого список «разрастался» при каждом прогоне.
    Product.where(category_id: cid).where.not(sku: skus).find_each(batch_size: 200) do |product|
      fallback =
        CategoryProduct
          .where(product_id: product.id)
          .where.not(category_id: cid)
          .order(:category_id)
          .pick(:category_id)
      product.update_columns(category_id: fallback)
    end

    n
  end

  def ensure_category_links_for_listing!(category, canonical_skus)
    cid = category.ikea_id.to_s
    skus = expanded_listing_skus_for_category_job(canonical_skus)
    return 0 if skus.empty?

    created_links = 0
    Product.where(sku: skus).find_each(batch_size: 500) do |product|
      cp = CategoryProduct.find_or_create_by!(product: product, category_id: cid)
      created_links += 1 if cp.previously_new_record?
    end
    created_links
  rescue StandardError => e
    Rails.logger.error "RefreshCategoryFromLtJob: ensure links failed for category=#{category.ikea_id}: #{e.message}"
    0
  end

  # Листинг и БД расходятся по виду SKU (s12345678 vs 12345678). Для where(sku: …) и отвязки нужны все алиасы.
  def expanded_listing_skus_for_category_job(canonical_skus)
    Array(canonical_skus).flat_map { |s| Products::ListingSkuResolver.aliases(s) }.map(&:to_s).map(&:strip).reject(&:blank?).uniq
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
