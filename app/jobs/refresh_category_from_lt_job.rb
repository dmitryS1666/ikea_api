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
#      related_products в API — см. CategoryRelatedProductList (сбор с 1-го и последнего SKU листинга);
#      per-product related_products в БД — см. RelatedProductsCollection::ENABLED и process_related.
#      Затем IkeaLvProductVariantsService (force: true) — цвет/размер с PIP.
#      Плюс depth-1 SKU из listing gprDescription.variants (макс. 8, без вложенных джоб).
#      Затем ImageDownloader.sync_product_images (после вариантов и ensure) — локальные WebP + зеркало в public/images.
#   5) Опционально: lt_jsonl_path в payload — строки JSONL по SKU (и алиасам) для приоритета LT;
#      process_related: true в payload — ReferencedProductsEnsureService (связанные в БД + категория).
#
# Контракт API с фронтом не меняется: те же поля ProductSerializer, типы и структура variants.
class RefreshCategoryFromLtJob < ApplicationJob
  queue_as :parser

  PRODUCT_CHECKPOINT_KEY = "product_checkpoint".freeze

  class ProductStageIncompleteError < StandardError; end

  def perform(ikea_id:, task_id: nil, max_created: nil, threads: 2, manage_task: true, strict_product_stage: nil)
    # Catalog orchestration (manage_task: false) keeps going when some SKUs fail headless;
    # standalone LT refresh still fails the whole task on incomplete products.
    @strict_product_stage = strict_product_stage.nil? ? manage_task : !!strict_product_stage

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
    threads =
      if payload["threads"].present?
        payload["threads"].to_i
      else
        threads.to_i
      end
    threads = 1 if threads <= 0
    threads = 10 if threads > 10

    category = Category.find_by(ikea_id: ikea_id.to_s)
    raise ActiveRecord::RecordNotFound, "Category not found for ikea_id=#{ikea_id}" unless category
    check_task_not_stopped!(task)
    task.mark_as_running! if manage_task

    notify_started("refresh_category_lt", limit: nil) if manage_task
    started = Time.current

    unless CategoryLtListingService.pl_listing_url(category)
      msg = "Нет URL категории (или нечисловой ikea_id) — невозможно построить адрес витрины PL"
      if manage_task
        task.mark_as_failed!(msg)
        notify_error("refresh_category_lt", StandardError.new(msg))
        return
      end
      raise StandardError, msg
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
      missing_related_skus: [],
      listing_errors: [],
      products_total: 0,
      products_resumed: 0,
      products_completed: 0,
      failed_enrichment_skus: []
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

      @category_listing_skus = all_pl_products.filter_map do |row|
        Products::ListingSkuResolver.coerce_listing_identifier(row)
      end.uniq
      @listing_variant_skus_by_sku = {}

      begin
        Products::CategoryRelatedProductsHarvestService.call(category: category, listing_rows: all_pl_products)
      rescue StandardError => e
        Rails.logger.error "RefreshCategoryFromLtJob: category related harvest failed ikea_id=#{category.ikea_id}: #{e.message}"
      end

      # 2. Обрабатываем каждый продукт
      products_to_enrich = []
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
        products_to_enrich << product.id
        
        break if max_created.present? && stats[:created] >= max_created
      end

      product_checkpoint = prepare_product_checkpoint!(task, category, products_to_enrich)
      product_checkpoint["listing_errors"] = stats[:listing_errors]
      task.update_payload!(PRODUCT_CHECKPOINT_KEY => product_checkpoint.deep_dup)
      stats[:products_total] = product_checkpoint["listing_skus"].size
      stats[:products_resumed] = product_checkpoint["completed_skus"].size

      enrich_products_batch!(
        products_to_enrich: products_to_enrich,
        category: category,
        rows_by_sku: rows_by_sku,
        task: task,
        stats: stats,
        process_related: process_related,
        threads: threads,
        checkpoint: product_checkpoint
      )

      product_checkpoint = task.reload.payload.to_h[PRODUCT_CHECKPOINT_KEY].to_h
      stats[:products_completed] = Array(product_checkpoint["completed_skus"]).size
      stats[:failed_enrichment_skus] = product_checkpoint.fetch("failed_skus", {}).to_h.keys.map(&:to_s)

      touched_canonical_skus.compact!
      touched_canonical_skus.uniq!
      canonical_listing_skus.replace(touched_canonical_skus)
      keep_skus = (canonical_listing_skus + remembered_listing_variant_skus).uniq

      stats[:linked] = ensure_category_links_for_listing!(category, keep_skus)

      if detach_orphans && canonical_listing_skus.any?
        stats[:detached] = detach_category_products_not_in_listing(category, keep_skus)
      end

      stats[:duration] = Time.current - started
      stats[:related_skus] = stats[:related_skus].uniq.sort
      stats[:related_skus_count] = stats[:related_skus].size
      stats[:missing_related_skus] = stats[:missing_related_skus].uniq.sort
      stats[:missing_related_skus_count] = stats[:missing_related_skus].size
      task.update_payload!("created_skus" => stats[:created_skus]) if stats[:created_skus].present?
      # Standalone category parsing must also refresh exact IKEA facet
      # memberships. RefreshCategoryCatalogJob passes manage_task: false and
      # performs the same step synchronously as part of its own pipeline.
      RefreshCategoryFilterIndexJob.perform_later(category.ikea_id) if manage_task
      task.mark_as_completed!(stats) if manage_task
      notify_completed("refresh_category_lt", stats) if manage_task
      stats
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        Rails.logger.info "RefreshCategoryFromLtJob: task #{task.id} stopped manually"
        raise unless manage_task
        return
      end

      Rails.logger.error "RefreshCategoryFromLtJob: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
      if manage_task
        task.mark_as_failed!(e.message)
        notify_error("refresh_category_lt", e)
      else
        raise
      end
    end
  end

  private

  def enrich_products_batch!(products_to_enrich:, category:, rows_by_sku:, task:, stats:, process_related:, threads:, checkpoint:)
    product_ids = pending_product_ids(products_to_enrich, checkpoint)
    if product_ids.empty?
      raise_product_stage_incomplete!(task, checkpoint)
      finalize_product_checkpoint!(task, checkpoint)
      return
    end

    checkpoint_mutex = Mutex.new

    if threads <= 1
      Product.where(id: product_ids).find_each(batch_size: 100) do |product|
        outcome = enrich_product!(product, category, rows_by_sku, task, stats, nil, process_related: process_related)
        persist_product_checkpoint_result!(task, checkpoint, product, outcome)
      end
      raise_product_stage_incomplete!(task, checkpoint)
      finalize_product_checkpoint!(task, checkpoint)
      return
    end

    queue = Queue.new
    product_ids.each { |id| queue << id }
    mutex = Mutex.new
    fatal_error = nil

    workers = Array.new(threads) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          loop do
            break if mutex.synchronize { fatal_error.present? }

            product_id = queue.pop(true)
            check_task_not_stopped!(task)
            product = Product.find_by(id: product_id)
            next unless product

            outcome = enrich_product!(product, category, rows_by_sku, task, stats, mutex, process_related: process_related)
            checkpoint_mutex.synchronize do
              persist_product_checkpoint_result!(task, checkpoint, product, outcome)
            end
          rescue ThreadError
            break
          rescue StandardError => e
            Rails.logger.warn "RefreshCategoryFromLtJob: enrich worker failed: #{e.class} #{e.message}"
            mutex.synchronize { fatal_error ||= e }
            break
          end
        end
      end
    end

    workers.each(&:join)
    raise fatal_error if fatal_error

    raise_product_stage_incomplete!(task, checkpoint)
    finalize_product_checkpoint!(task, checkpoint)
  end

  def enrich_product!(product, category, rows_by_sku, task, stats, mutex, process_related: false)
    check_task_not_stopped!(task)

    outcome = { ok: true }

    begin
      row = jsonl_row_for_product(rows_by_sku, product.sku)
      # Принудительно используем ИИ-перевод, если нет на LT
      ext = Products::ExtendedAttributesFetchService.fetch_for_product(
        product,
        results_jsonl_row: row,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true,
        skip_document_download: true
      )
      
      if mutex
        mutex.synchronize { stats[:updated] += 1 if ext[:updated] }
      else
        stats[:updated] += 1 if ext[:updated]
      end

      product.reload
      merge_product_accessories_into_category_related!(product, category)

      # ВАЖНО:
      # ExtendedAttributesFetchService уже записал полную PL-галерею в product.images
      # и мог сбросить local_images в [].
      # Скачиваем основную галерею сразу, до вариантов/included/related,
      # чтобы при ошибке ниже товар не остался с images, но без local_images.
      sync_local_images!(product, stats, mutex)

      # Варианты (PIP PL): variants_payload с URL картинок по цветам/размерам
      vres = IkeaLvProductVariantsService.new(product: product, force: true).call
      if mutex
        mutex.synchronize { stats[:updated] += 1 if vres[:changed] }
      else
        stats[:updated] += 1 if vres[:changed]
      end

      product.reload

      extras = listing_variant_skus_for(product)
      if product.variants_payload.present? || extras.any?
        # Depth 1 only: PIP color/size + capped listing extras. No nested jobs.
        Products::VariantProductsEnsureService.ensure!(
          product,
          category: category,
          extra_skus: extras,
          enqueue_jobs: false,
          include_column_skus: false
        )
      end

      # В одном проходе контролируем качество вариантов: описания/материалы/картинки.
      ensure_variant_siblings_quality!(product, category, task, stats, mutex)

      related_in_base, related_missing = collect_related_skus_for(product, category: category)
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
      raise if e.message == "Task was stopped manually"

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
      outcome = {
        ok: false,
        error_class: e.class.name,
        message: e.message.to_s
      }
    ensure
      ensure_included_products_bootstrap!(product)
    end

    outcome
  end

  def prepare_product_checkpoint!(task, category, product_ids)
    listing_skus = Product.where(id: Array(product_ids).compact.uniq).pluck(:sku).map(&:to_s).uniq
    saved = task.reload.payload.to_h[PRODUCT_CHECKPOINT_KEY].to_h.deep_stringify_keys

    checkpoint =
      if saved["category_ikea_id"].to_s == category.ikea_id.to_s
        saved
      else
        {}
      end

    completed_skus = Array(checkpoint["completed_skus"]).map(&:to_s) & listing_skus
    failed_skus = checkpoint.fetch("failed_skus", {}).to_h.slice(*listing_skus)
    checkpoint = {
      "category_ikea_id" => category.ikea_id.to_s,
      "stage" => "products",
      "listing_skus" => listing_skus,
      "completed_skus" => completed_skus,
      "failed_skus" => failed_skus,
      "products_total" => listing_skus.size,
      "products_completed" => completed_skus.size,
      "updated_at" => Time.current.iso8601
    }
    task.update_payload!(PRODUCT_CHECKPOINT_KEY => checkpoint)
    checkpoint
  end

  def pending_product_ids(product_ids, checkpoint)
    completed_skus = Array(checkpoint["completed_skus"]).map(&:to_s)

    Product.where(id: Array(product_ids).compact.uniq).filter_map do |product|
      product.id unless completed_skus.include?(product.sku.to_s)
    end
  end

  def persist_product_checkpoint_result!(task, checkpoint, product, outcome)
    sku = product.sku.to_s
    completed_skus = Array(checkpoint["completed_skus"]).map(&:to_s)
    failed_skus = checkpoint.fetch("failed_skus", {}).to_h

    if outcome[:ok]
      completed_skus |= [sku]
      failed_skus.delete(sku)
    else
      completed_skus.delete(sku)
      failed_skus[sku] = {
        "error_class" => outcome[:error_class].to_s,
        "message" => outcome[:message].to_s,
        "failed_at" => Time.current.iso8601
      }
    end

    checkpoint["completed_skus"] = completed_skus
    checkpoint["failed_skus"] = failed_skus
    checkpoint["products_completed"] = completed_skus.size
    checkpoint["last_product_sku"] = sku
    checkpoint["updated_at"] = Time.current.iso8601
    task.update_payload!(PRODUCT_CHECKPOINT_KEY => checkpoint.deep_dup)
  end

  def raise_product_stage_incomplete!(task, checkpoint, strict: nil)
    strict = @strict_product_stage if strict.nil?
    # Standalone / unspecified callers keep abort-on-incomplete behavior.
    strict = true if strict.nil?

    failed_skus = checkpoint.fetch("failed_skus", {}).to_h
    listing_errors = Array(checkpoint["listing_errors"])
    completed_skus = Array(checkpoint["completed_skus"]).map(&:to_s)
    unprocessed_skus = Array(checkpoint["listing_skus"]).map(&:to_s) - completed_skus - failed_skus.keys
    unprocessed_skus.each do |sku|
      failed_skus[sku] = {
        "error_class" => "ProductNotProcessed",
        "message" => "product disappeared or worker stopped before enrichment",
        "failed_at" => Time.current.iso8601
      }
    end
    checkpoint["failed_skus"] = failed_skus
    return if failed_skus.empty? && listing_errors.empty?

    checkpoint["updated_at"] = Time.current.iso8601
    task.update_payload!(PRODUCT_CHECKPOINT_KEY => checkpoint.deep_dup)

    unless strict
      Rails.logger.warn(
        "RefreshCategoryFromLtJob: products stage incomplete (soft): " \
        "#{failed_skus.size} SKU failed, #{listing_errors.size} listing errors; " \
        "continuing without aborting the category"
      )
      return
    end

    if failed_skus.any?
      first_sku, first_error = failed_skus.first
      raise ProductStageIncompleteError,
            "products stage incomplete: #{failed_skus.size} SKU failed; " \
            "first=#{first_sku}: #{first_error.to_h['message']}"
    end

    first_error = listing_errors.first.to_h
    raise ProductStageIncompleteError,
          "products listing incomplete: #{listing_errors.size} row failed; " \
          "first=#{first_error['sku']}: #{first_error['message']}"
  end

  def finalize_product_checkpoint!(task, checkpoint)
    checkpoint["stage"] = "products_completed"
    checkpoint["products_completed"] = Array(checkpoint["completed_skus"]).size
    # Keep failed_skus for catalog quality reporting / resume; empty on full success.
    checkpoint["failed_skus"] = checkpoint.fetch("failed_skus", {}).to_h
    checkpoint["updated_at"] = Time.current.iso8601
    task.update_payload!(PRODUCT_CHECKPOINT_KEY => checkpoint.deep_dup)
  end

  def ensure_included_products_bootstrap!(product)
    product.reload
    Products::IncludedProductsBootstrapService.ensure!(product)
  rescue StandardError => e
    Rails.logger.error "RefreshCategoryFromLtJob: included bootstrap #{product.sku}: #{e.message}"
  end

  def jsonl_row_for_product(rows_by_sku, sku)
    Products::ListingSkuResolver.aliases(sku).each do |key|
      row = rows_by_sku[key.to_s]
      return row if row.present?
    end
    nil
  end

  def sync_local_images!(product, stats, mutex)
    remote_images =
      json_array(product.images)
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
  
    if remote_images.empty?
      clear_local_images_for_refresh!(product)
      Rails.logger.info(
        "RefreshCategoryFromLtJob: images skipped sku=#{product.sku} remote=0 local=#{json_array(product.local_images).size}"
      )
      return
    end
  
    result = ImageDownloader.sync_product_images(product)
  
    product.reload
    local_count = json_array(product.local_images).size
  
    Rails.logger.info(
      "RefreshCategoryFromLtJob: images synced sku=#{product.sku} remote=#{remote_images.size} local=#{local_count} changed=#{result[:changed]}"
    )
  
    return unless result[:changed]
  
    if mutex
      mutex.synchronize { stats[:images_synced] += 1 }
    else
      stats[:images_synced] += 1
    end
  rescue StandardError => e
    Rails.logger.warn "RefreshCategoryFromLtJob: images sku=#{product.sku}: #{e.message}"
  end

  def ensure_variant_gallery_from_payload_sku!(product, payload_sku)
    current_images = json_array(product.images)
    current_local = json_array(product.local_images)
  
    # Если уже есть полноценная галерея и локальные картинки — не трогаем.
    return false if current_images.size > 1 && current_local.size > 1
  
    payload_sku = payload_sku.to_s.strip
    return false if payload_sku.blank?
  
    candidates =
      ([payload_sku] + Products::ListingSkuResolver.aliases(payload_sku))
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
  
    candidates.each do |candidate_sku|
      details = PlDetailsFetcher.fetch(
        "https://www.ikea.com/pl/pl/p/-#{candidate_sku}/",
        use_headless: false,
        scope_sku: candidate_sku
      )
  
      images =
        Array(details[:images])
          .map(&:to_s)
          .map(&:strip)
          .reject(&:blank?)
          .uniq
  
      next if images.empty?
  
      write_remote_images_for_refresh!(product, images)
  
      Rails.logger.info(
        "RefreshCategoryFromLtJob: variant gallery fallback sku=#{product.sku} payload_sku=#{payload_sku} candidate=#{candidate_sku} images=#{images.size}"
      )
  
      return true
    rescue StandardError => e
      Rails.logger.warn(
        "RefreshCategoryFromLtJob: variant gallery fallback failed sku=#{product.sku} payload_sku=#{payload_sku} candidate=#{candidate_sku}: #{e.message}"
      )
    end
  
    false
  end

  def write_remote_images_for_refresh!(product, images)
    images =
      Array(images)
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
  
    return false if images.empty?
  
    attrs = {
      images: typed_json_column_value(product, :images, images),
      updated_at: Time.current
    }
  
    if Product.column_names.include?("local_images")
      attrs[:local_images] = typed_json_column_value(product, :local_images, [])
    end
  
    product.update_columns(attrs)
    true
  end
  
  def typed_json_column_value(record, column, value)
    attr_type = record.class.type_for_attribute(column.to_s).type
    [:json, :jsonb].include?(attr_type) ? value : value.to_json
  end

  def json_array(value)
    return value if value.is_a?(Array)
    return [] if value.blank?
  
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  def clear_local_images_for_refresh!(product)
    return unless product.respond_to?(:local_images)
    return unless Product.column_names.include?("local_images")
  
    current =
      json_array(product.local_images)
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
  
    return if current.empty?
  
    attr_type = product.class.type_for_attribute("local_images").type
    value = [:json, :jsonb].include?(attr_type) ? [] : [].to_json
  
    product.update_column(:local_images, value)
  
    Rails.logger.info(
      "RefreshCategoryFromLtJob: cleared stale local_images for sku=#{product.sku} because remote images are empty"
    )
  rescue StandardError => e
    Rails.logger.warn(
      "RefreshCategoryFromLtJob: clear local_images failed sku=#{product.sku}: #{e.message}"
    )
  end

  # Отдельные Product по SKU из variants / variants_payload — догружаем local_images (ActiveStorage + зеркало в public)
  def sync_variant_siblings_images!(parent, stats, mutex)
    skus = variant_skus_for(parent)
    return if skus.empty?

    skus.each do |vs|
      other = Products::ListingSkuResolver.find_product(vs) || Product.find_by(sku: vs)
      next unless other
      next if json_array(other.images).compact.reject(&:blank?).empty?

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
        fallback_pl_when_lt_missing: true,
        skip_document_download: true
      )

      if ext[:updated]
        if mutex
          mutex.synchronize { stats[:updated] += 1 }
        else
          stats[:updated] += 1
        end
      end

      other.reload

      # ВАЖНО:
      # Для вариантов из variants_payload исходный SKU может быть s49537066,
      # а товар в БД найден как 49537066.
      # Если обычный ExtendedAttributesFetchService не наполнил галерею,
      # достаём PL-галерею напрямую по исходному payload SKU.
      ensure_variant_critical_pl_data_from_payload_sku!(other, vs)

      other.reload

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

  def ensure_variant_critical_pl_data_from_payload_sku!(product, payload_sku)
    payload_sku = payload_sku.to_s.strip
    return false if payload_sku.blank?
  
    current_images = json_array(product.images)
    current_local = json_array(product.local_images)
    current_mm = product.full_attributes.is_a?(Hash) ? product.full_attributes.deep_stringify_keys["measurements_modal"] : nil
  
    # Если уже есть нормальные картинки И физические упаковки — не трогаем.
    if current_images.size > 1 &&
       current_local.size > 1 &&
       measurements_modal_has_physical_packages?(current_mm)
      return false
    end
  
    candidates =
      ([payload_sku] + Products::ListingSkuResolver.aliases(payload_sku))
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
  
    needs_images = current_images.size <= 1
    candidates.each do |candidate_sku|
      details = PlDetailsFetcher.fetch(
        "https://www.ikea.com/pl/pl/p/-#{candidate_sku}/",
        use_headless: needs_images,
        scope_sku: candidate_sku
      )
  
      next if details.blank?
  
      attrs = {}
  
      %i[dimensions weight net_weight package_volume package_dimensions].each do |key|
        attrs[key] = details[key] if details[key].present?
      end
  
      if details[:measurements_modal].present?
        full = product.full_attributes.is_a?(Hash) ? product.full_attributes.deep_stringify_keys : {}
        full["measurements_modal"] = details[:measurements_modal].is_a?(Hash) ? details[:measurements_modal].deep_stringify_keys : details[:measurements_modal]
        full["measurements_modal_extracted_at"] = Time.current.iso8601
        attrs[:full_attributes] = typed_json_column_value(product, :full_attributes, full)
      end
  
      images =
        Array(details[:images])
          .map(&:to_s)
          .map(&:strip)
          .reject(&:blank?)
          .uniq
  
      if images.any?
        attrs[:images] = typed_json_column_value(product, :images, images)
        attrs[:local_images] = typed_json_column_value(product, :local_images, []) if Product.column_names.include?("local_images")
      end
  
      next if attrs.empty?
  
      attrs[:updated_at] = Time.current
      product.update_columns(attrs)
  
      Rails.logger.info(
        "RefreshCategoryFromLtJob: variant critical PL fallback sku=#{product.sku} payload_sku=#{payload_sku} candidate=#{candidate_sku} images=#{images.size} measurements=#{details[:measurements_modal].present?}"
      )
  
      return true
    rescue StandardError => e
      Rails.logger.warn(
        "RefreshCategoryFromLtJob: variant critical PL fallback failed sku=#{product.sku} payload_sku=#{payload_sku} candidate=#{candidate_sku}: #{e.message}"
      )
    end
  
    false
  end
  
  def measurements_modal_has_physical_packages?(mm)
    return false unless mm.is_a?(Hash)
  
    packages = Array(mm["packages"] || mm[:packages])
    return false if packages.empty?
  
    packages.any? do |pkg|
      measurements = Array(pkg["measurements"] || pkg[:measurements])
      names = measurements.map { |m| (m["name"] || m[:name]).to_s }
      names.include?("Ширина") &&
        names.include?("Высота") &&
        names.include?("Длина") &&
        names.include?("Вес")
    end
  end

  def variant_skus_for(parent)
    # Для LT-refresh берём только реальные варианты из variants_payload,
    # который собирает IkeaLvProductVariantsService из PIP style/variant picker.
    #
    # parent.normalized_variant_skus здесь использовать нельзя:
    # для set/combo товаров IKEA туда могут попадать комплектующие набора,
    # например части дивана, а не цветовые/размерные варианты.
    from_payload =
      Products::VariantProductsEnsureService
        .variant_skus_from_variants_payload(parent.variants_payload)

    parent_aliases =
      Products::ListingSkuResolver.aliases(parent.sku).map(&:to_s)

    (from_payload + listing_variant_skus_for(parent))
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .uniq
      .reject { |sku| parent_aliases.include?(sku) }
  end

  def merge_product_accessories_into_category_related!(product, category)
    return if product.blank? || category.blank?

    related = Array(product.related_products)
    return if related.empty?

    excluded = [product.sku, product.item_no] + Array(product.included_products) + Array(product.set_items)
    Products::CategoryRelatedProductsHarvestService.merge_skus!(
      category: category,
      skus: related,
      exclude_skus: excluded,
      anchor_sku: product.sku
    )
  rescue StandardError => e
    Rails.logger.warn(
      "RefreshCategoryFromLtJob: category related merge failed " \
      "category=#{category&.ikea_id} sku=#{product&.sku}: #{e.message}"
    )
  end

  def collect_related_skus_for(parent, category: nil)
    products = [parent]
    variant_skus_for(parent).each do |vs|
      p = Products::ListingSkuResolver.find_product(vs) || Product.find_by(sku: vs)
      products << p if p
    end

    list_category_ids = [parent.category_id, category&.ikea_id].compact.map(&:to_s).uniq
    category_related = list_category_ids.flat_map { |cid| CategoryRelatedProductList.skus_array_for_category_id(cid) }.uniq

    normalized_articles =
      (category_related + products.flat_map do |p|
        Array(p.related_products) +
          Array(p.included_products) +
          Array(p.set_items)
      end)
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

  def process_one_listing_item(product_data, parser, category, availability_data, task, stats, mutex)
    check_task_not_stopped!(task)

    begin
      res = parser.send(:process_product, product_data, category, availability_data)
      if res[:created] || res[:updated]
        apply_listing_stats(res, task, stats, mutex)
      end
      sku = res[:sku].presence
      remember_listing_variant_skus!(sku, product_data) if sku.present?
      sku
    rescue StandardError => e
      Rails.logger.error "RefreshCategoryFromLtJob: product error #{e.message}"
      listing_sku = Products::ListingSkuResolver.coerce_listing_identifier(product_data)
      listing_error = {
        "sku" => listing_sku.to_s.presence || "unknown",
        "error_class" => e.class.name,
        "message" => e.message.to_s
      }
      if mutex
        mutex.synchronize do
          stats[:errors] += 1
          stats[:listing_errors] << listing_error
          task.increment_errors!
        end
      else
        stats[:errors] += 1
        stats[:listing_errors] << listing_error
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

  def remember_listing_variant_skus!(parent_sku, product_data)
    extras = Products::ListingVariantSkus.from_listing_row(
      product_data,
      parent_sku: parent_sku,
      exclude: @category_listing_skus
    )
    @listing_variant_skus_by_sku ||= {}
    Products::ListingSkuResolver.aliases(parent_sku).each do |key|
      @listing_variant_skus_by_sku[key.to_s] = extras
    end
  end

  def listing_variant_skus_for(product)
    @listing_variant_skus_by_sku ||= {}
    Products::ListingSkuResolver.aliases(product.sku).each do |key|
      found = @listing_variant_skus_by_sku[key.to_s]
      return found if found
    end
    []
  end

  def remembered_listing_variant_skus
    Array(@listing_variant_skus_by_sku&.values).flatten.map(&:to_s).uniq
  end
end
