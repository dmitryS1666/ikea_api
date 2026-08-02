# frozen_string_literal: true

# Расширенные поля товара из витрин IKEA.
#
# Приоритет для товаров LT (ikea.com/lt/ru или строка results_jsonl с витрины LT):
#   — описания, материалы, характеристики, ВГХ (вес, габариты, объём), картинки — с LT;
#   — опционально строка JSONL (ключ "Подробная информация о товаре") — полный снимок с LT-парсера;
#   — цена и остаток — с PL (zł / API) и API наличия;
#   — варианты: списки SKU с LT и с PL объединяются (PL PIP часто даёт itemNo / полную матрицу).
#
# Если страница LT недоступна и передан `fallback_pl_when_lt_missing: true`, не прерываем загрузку:
# подтягиваем описательные поля с PL и не требуем OpenAI (`force_ai_translation` остаётся для явного ИИ-fallback).
#
# Связи наборов / сопутствующие SKU и документы без LT — дополняются с PL, если пусто.
class Products::ExtendedAttributesFetchService
  HEADLESS_FETCH_MAX_ATTEMPTS = 3
  HEADLESS_RETRY_DELAYS = [1, 2].freeze

  class HeadlessRetriesExhaustedError < StandardError; end

  # Старые URL фото с польской витрины (часто смесь вариантов цвета); при новом парсе PL их выкидываем и подставляем список под текущий SKU.
  REMOTE_PL_PRODUCT_IMAGE_URL = %r{\Ahttps?://www\.ikea\.com/pl/pl/images/products}i.freeze
  # Любая витрина IKEA (pl, lt/ru, …) — один и тот же каталог фото; при смене scoped-галереи вычищаем все, иначе LT+PL копятся в кашу.
  REMOTE_IKEA_PRODUCT_GALLERY_URL = %r{\Ahttps?://www\.ikea\.com/[^/]+/[^/]+/images/products}i.freeze

  def self.fetch_for_product(product, results_jsonl_row: nil, force_ai_translation: false, fallback_pl_when_lt_missing: false, strip_listing_relations: false, skip_document_download: false, skip_image_reconciliation: false, bundle_component: false)
    new.fetch(
      product,
      results_jsonl_row: results_jsonl_row,
      force_ai_translation: force_ai_translation,
      fallback_pl_when_lt_missing: fallback_pl_when_lt_missing,
      strip_listing_relations: strip_listing_relations,
      skip_document_download: skip_document_download,
      skip_image_reconciliation: skip_image_reconciliation,
      bundle_component: bundle_component
    )
  end

  def fetch(product, results_jsonl_row: nil, force_ai_translation: false, fallback_pl_when_lt_missing: false, strip_listing_relations: false, skip_document_download: false, skip_image_reconciliation: false, bundle_component: false)
    @skip_document_download = skip_document_download
    @skip_image_reconciliation = skip_image_reconciliation
    @bundle_component = bundle_component
    pl_url = pl_product_url(product)
    return { updated: false } if pl_url.blank?

    pl_details = fetch_details_with_optional_headless(pl_url, scope_sku: product.sku)
    return { updated: false } if pl_details.blank?

    lt_url = lt_product_url(product)
    use_lt_descriptive = lt_url.present? && lt_url != pl_url
    lt_details = use_lt_descriptive ? fetch_details_with_optional_headless(lt_url, scope_sku: product.sku) : {}

    if use_lt_descriptive && lt_details.blank?
      # ПОДСТРАХОВКА: Если по первому артикулу (из SKU) LT не ответил, пробуем второй (из item_no)
      db_article = product.item_no.to_s.gsub(/[^0-9a-z]/i, "").presence
      match = product.sku.to_s.match(/(\d{8})/)
      sku_article = match ? match[1] : nil
      
      if db_article.present? && db_article != sku_article
        alt_lt_url = "https://www.ikea.com/lt/ru/p/-#{db_article}/"
        Rails.logger.info "ExtendedAttributesFetchService: LT primary URL failed for #{product.sku}, trying alternative: #{alt_lt_url}"
        lt_details = fetch_details_with_optional_headless(alt_lt_url, scope_sku: product.sku)
      end

      if lt_details.blank?
        if force_ai_translation
          Rails.logger.info "ExtendedAttributesFetchService: LT data missing for #{product.sku} after all attempts, falling back to AI translation of PL data"
          use_lt_descriptive = false
        elsif fallback_pl_when_lt_missing
          Rails.logger.info "ExtendedAttributesFetchService: LT missing for #{product.sku}, using PL-only card (LT not required)"
          use_lt_descriptive = false
        else
          Rails.logger.warn "ExtendedAttributesFetchService: LT data missing for #{product.sku}, skipping product until translation fallback ready"
          return { updated: false, skipped_missing_lt: true }
        end
      end
    end

    jsonl_applied =
      results_jsonl_row.present? && Products::LtResultsJsonlAttributes.results_jsonl_row?(results_jsonl_row)

    Rails.logger.info "ExtendedAttributesFetchService: sku=#{product.sku} pl=#{pl_url} lt=#{use_lt_descriptive ? lt_url : '—'} jsonl=#{jsonl_applied}"

    attributes = {}
    seed_merge_state_from_product!(product, attributes)

    if jsonl_applied
      row_attrs = Products::LtResultsJsonlAttributes.to_product_attributes(product, results_jsonl_row)
      merge_jsonl_row_preserving_nonblank!(attributes, row_attrs)
      download_row_documents!(product, attributes)
      attributes[:translated] = true
      if use_lt_descriptive && lt_details.present?
        supplement_lt_descriptive_gaps(lt_details, attributes)
        merge_lt_structural(product, lt_details, attributes)
      end
    else
      if use_lt_descriptive && lt_details.present?
        apply_lt_descriptive(lt_details, attributes)
        merge_lt_structural(product, lt_details, attributes)
      elsif use_lt_descriptive && lt_details.blank?
        Rails.logger.warn "ExtendedAttributesFetchService: LT page empty for #{product.sku}, descriptive fields skipped"
      elsif pl_details.present?
        # Нужен fallback только если LT-источник недоступен/неопределим для товара.
        apply_pl_descriptive(pl_details, attributes)
      end
    end

    if use_lt_descriptive || jsonl_applied
      merge_pl_with_lt_priority(product, pl_details, attributes)
    else
      merge_pl_structural_and_commerce(product, pl_details, attributes)
    end

    supplement_materials_from_lt_modal!(lt_details, attributes) if use_lt_descriptive && lt_details.present?
    supplement_descriptive_from_pl_modal!(pl_details, attributes)

    supplement_from_ikea_lt_legacy(product, attributes) if use_lt_descriptive && !jsonl_applied

    assign_product_details_modal_to_full_attributes!(product, pl_details, lt_details, use_lt_descriptive, attributes)
    assign_measurements_modal_to_full_attributes!(product, pl_details, lt_details, use_lt_descriptive, attributes)
    assign_inferred_variant_type!(product, pl_details, attributes)

    mirror_ru_for_lt_text!(attributes)
    apply_russian_translations_for_polish_fields!(product, attributes, force: force_ai_translation)
    translate_polish_in_stored_product_details_modal!(attributes, force: force_ai_translation)
    sync_materials_and_care_from_product_details_modal!(attributes)
    translate_polish_in_detailed_info!(attributes, force: force_ai_translation)
    apply_russian_translations_for_polish_fields!(product, attributes, force: force_ai_translation)

    # ВАЖНО:
    # Название серии/товара IKEA не переводим.
    # name/name_ru должны оставаться как на сайте-источнике: BÅRSLÖV, VIMLE, BESTÅ и т.п.
    # Переводим только описание, материалы, уход, безопасность и small_desc_name.
    preserve_source_product_name!(product, pl_details, attributes)

    if strip_listing_relations
      attributes[:variants] = []
      attributes[:related_products] = []
      attributes[:variants_payload] = nil if Product.column_names.include?("variants_payload")
    end

    strip_nil_overwrites_from_product!(product, attributes)

    if attributes.any?
      product.update!(attributes)
    end
    if pl_details.present? && (pl_details[:pl_breadcrumb_category_ids].present? || pl_details["pl_breadcrumb_category_ids"].present?)
      link_product_to_pl_breadcrumb_categories!(product, pl_details)
    end

    { updated: attributes.any? }
  end

  private

  def preserve_source_product_name!(product, pl_details, attributes)
    source_name =
      pl_details[:name].presence ||
      pl_details["name"].presence ||
      attributes[:name].presence ||
      product.name.to_s
  
    clean_name = normalize_ikea_product_name(source_name)
    return if clean_name.blank?
  
    attributes[:name] = clean_name if Product.column_names.include?("name")
    attributes[:name_ru] = clean_name if Product.column_names.include?("name_ru")
  end
  
  def normalize_ikea_product_name(value)
    s = value.to_s.gsub(/\u00A0/, " ").gsub(/\s+/, " ").strip
    return nil if s.blank?
  
    # Если прилетело "BÅRSLÖV, 3-os sofa..."
    s = s.split(",").first.to_s.strip
  
    # BÅRSLÖV БОРСЛЁВ -> BÅRSLÖV
    # BESTÅ БЕСТО -> BESTÅ
    # IKEA 365+ ИКЕА 365+ -> IKEA 365+
    s = s.sub(/\s+[А-ЯЁа-яё].*\z/, "").strip
  
    s.presence
  end

  # Сайт-источник: цепочка /cat/...-{id} в шапке товара. Создаём CategoryProduct и ставим products.category_id на листовой id.
  def link_product_to_pl_breadcrumb_categories!(product, pl_details)
    raw = pl_details[:pl_breadcrumb_category_ids] || pl_details["pl_breadcrumb_category_ids"]
    return if raw.blank?

    ids = Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    return if ids.empty?

    leaf = ids.last
    ids.each do |ikea_cid|
      next unless Category.exists?(ikea_id: ikea_cid)

      CategoryProduct.find_or_create_by!(product: product, category_id: ikea_cid)
    end

    if leaf.present? && Category.exists?(ikea_id: leaf) && product.read_attribute(:category_id).to_s != leaf
      product.update_column(:category_id, leaf)
    end
  rescue StandardError => e
    Rails.logger.warn "ExtendedAttributesFetchService: pl breadcrumb link sku=#{product.sku}: #{e.class} #{e.message}"
  end

  def strip_remote_pl_ikea_gallery_urls(urls)
    Array(urls).reject { |u| REMOTE_PL_PRODUCT_IMAGE_URL.match?(u.to_s) }
  end

  def strip_all_ikea_remote_gallery_urls(urls)
    Array(urls).reject { |u| remote_ikea_gallery_url?(u) }
  end

  def remote_ikea_gallery_url?(url)
    REMOTE_IKEA_PRODUCT_GALLERY_URL.match?(url.to_s) || REMOTE_PL_PRODUCT_IMAGE_URL.match?(url.to_s)
  end

  # Scoped-список с PL (PlDetailsFetcher + scope_sku) — единственный источник удалённых URL; сбрасываем local_images чтобы перекачать под новый набор.
  def reconcile_pl_scoped_product_images!(product, pl_details, attributes)
    return if @skip_image_reconciliation
    return unless pl_details.key?(:images) && pl_details[:images].is_a?(Array)
  
    pl_images =
      pl_details[:images]
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
  
    original = parse_json_array(product.images)
  
    if pl_images.any?
      if pl_images != original || parse_json_array(attributes[:images]) != pl_images
        attributes[:images] = pl_images
  
        if product.respond_to?(:local_images) && Product.column_names.include?("local_images")
          attributes[:local_images] = []
        end
      end
  
      return
    end
  
    log_level = @bundle_component ? :info : :warn
    Rails.logger.public_send(
      log_level,
      "ExtendedAttributesFetchService: PL scoped images empty for sku=#{product.sku}; keeping images unchanged"
    )
  
    attributes.delete(:images)
  end

  MERGE_SEED_FIELDS = %i[
    name_ru name short_desc_name short_description content materials features
    care_instructions environmental_info designer safety_info good_to_know
    dimensions dimensions_ru weight net_weight package_volume package_dimensions collection
    short_description_ru content_ru materials_ru features_ru care_instructions_ru
    environmental_info_ru designer_ru safety_info_ru good_to_know_ru
    related_products included_products videos manuals assembly_documents
  ].freeze

  def seed_merge_state_from_product!(product, attributes)
    MERGE_SEED_FIELDS.each do |key|
      next unless Product.column_names.include?(key.to_s)

      val = product.read_attribute(key)
      next if val.blank?

      attributes[key] = val
    end

    fa = product.full_attributes
    return unless fa.is_a?(Hash) && fa.present?

    attributes[:full_attributes] = fa.deep_dup
  end

  def merge_jsonl_row_preserving_nonblank!(attributes, row_attrs)
    row_attrs.each do |k, v|
      key = k.is_a?(Symbol) ? k : k.to_sym
      next if v.nil?

      if v.respond_to?(:empty?) && v.empty? && attributes[key].present?
        next
      end

      attributes[key] = v
    end
  end

  # Не затираем вес/описания и т.д. значением nil из парсера, если в БД уже было значение.
  # Не даём nil из парсера затереть уже сохранённые богатые поля.
  STRIP_NIL_FOR = %i[
    weight net_weight dimensions dimensions_ru package_dimensions package_volume collection
    full_attributes name_ru name short_desc_name content materials features
    care_instructions environmental_info designer safety_info good_to_know
    short_description related_products included_products manuals assembly_documents
  ].freeze

  def strip_nil_overwrites_from_product!(product, attributes)
    STRIP_NIL_FOR.each do |k|
      next unless attributes.key?(k)
      next unless attributes[k].nil?

      old = product.read_attribute(k)
      next if old.nil?

      attributes.delete(k)
    end
  end

  def download_row_documents!(product, attributes)
    %i[manuals assembly_documents].each do |key|
      next if attributes[key].blank?
      attributes[key] = download_documents(attributes[key], product.sku)
    end
  end

  # LT: в product_details_modal — русские пары; колонка materials часто остаётся с PL.
  # Если в модалке есть пары, перезаписываем materials (и после jsonl — обычно то же по смыслу).
  def supplement_materials_from_lt_modal!(lt_details, attributes)
    modal = lt_details[:product_details_modal]
    return if modal.blank?

    h = ProductSerializer.materials_hash_from_product_details_modal(modal)
    return if h.blank?

    attributes[:materials] = h.map { |k, v| "#{k}: #{v}".strip }.reject(&:blank?).join("\n")
  end

  # PL: если парсер не вытащил description/materials в плоские поля, берём их из snapshot-модалки.
  def supplement_descriptive_from_pl_modal!(pl_details, attributes)
    modal = pl_details[:product_details_modal]
    return if modal.blank?

    if attributes[:content].blank?
      paras = Array(modal["intro_paragraphs"] || modal[:intro_paragraphs]).map(&:to_s).map(&:strip).reject(&:blank?)
      attributes[:content] = paras.join("\n\n") if paras.any?
    end

    return unless attributes[:materials].blank?

    materials_hash = ProductSerializer.materials_hash_from_product_details_modal(modal)
    if materials_hash.present?
      attributes[:materials] = materials_hash.map { |k, v| "#{k}: #{v}".strip }.reject(&:blank?).join("\n")
      return
    end

    materials_text = ProductSerializer.materials_text_from_product_details_modal(modal)
    attributes[:materials] = materials_text if materials_text.present?
  rescue StandardError => e
    Rails.logger.warn "ExtendedAttributesFetchService: PL modal supplement failed #{e.class}: #{e.message}"
  end

  def supplement_lt_descriptive_gaps(lt_details, attributes)
    if attributes[:content].blank? && lt_details[:description].present?
      attributes[:content] = lt_details[:description]
    end
    if attributes[:short_description].blank? && lt_details[:short_description].present?
      attributes[:short_description] = lt_details[:short_description]
    end
    if attributes[:materials].blank? && lt_details[:materials].present?
      attributes[:materials] =
        lt_details[:materials].is_a?(Array) ? lt_details[:materials].join("\n") : lt_details[:materials]
    end
    attributes[:features] = lt_details[:features] if attributes[:features].blank? && lt_details[:features].present?
    if attributes[:care_instructions].blank? && lt_details[:care_instructions].present?
      attributes[:care_instructions] = lt_details[:care_instructions]
    end
    if attributes[:environmental_info].blank? && lt_details[:environmental_info].present?
      attributes[:environmental_info] = lt_details[:environmental_info]
    end
    attributes[:designer] = lt_details[:designer] if attributes[:designer].blank? && lt_details[:designer].present?
    if attributes[:safety_info].blank? && lt_details[:safety_info].present?
      attributes[:safety_info] = lt_details[:safety_info]
    end
    if attributes[:good_to_know].blank? && lt_details[:good_to_know].present?
      attributes[:good_to_know] = lt_details[:good_to_know]
    end
    if attributes[:environmental_info].blank? && lt_details[:environmental_info].present?
      attributes[:environmental_info] = lt_details[:environmental_info]
    end
    if attributes[:small_desc_name].blank? && lt_details[:small_desc_name].present?
      attributes[:small_desc_name] = lt_details[:small_desc_name]
    end
  end

  def merge_lt_structural(product, lt_details, attributes)
    return if lt_details.blank?

    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      next if attributes[key].present?
      attributes[key] = lt_details[key] if lt_details[key].present?
    end

    if attributes[:small_desc_name].blank? && lt_details[:small_desc_name].present?
      attributes[:small_desc_name] = lt_details[:small_desc_name]
    end

    if lt_details[:variants].present? && attributes[:variants].blank?
      attributes[:variants] = normalize_variants_payload(lt_details[:variants])
    end

    # LT/RU PIP часто уже содержит .pipf-upsell-modal в готовом HTML.
    # Эти аксессуары относятся именно к текущей карточке товара, поэтому сохраняем
    # их в product.related_products, а не только в category_related_product_lists.
    merge_related_products_attribute!(product, lt_details, attributes)
  end

  def merge_pl_with_lt_priority(product, pl_details, attributes)
    # Уже взяли описательные поля с LT (ru) — не затираем польской витриной.
    lt_descriptive = attributes[:translated].present? || product.translated

    if pl_details[:name].present? && !lt_descriptive
      attributes[:name] = pl_details[:name]
      attributes[:name_ru] = pl_details[:name] if Product.column_names.include?("name_ru")
    end

    assign_valid_pl_price!(pl_details, attributes)
    update_quantity(product, pl_details, attributes)

    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      attributes[key] = pl_details[key] if pl_details[key].present? && attributes[key].blank?
    end

    reconcile_pl_scoped_product_images!(product, pl_details, attributes)

    attributes[:set_items] = pl_details[:set_items] if pl_details[:set_items].present? && attributes[:set_items].blank?
    merge_related_products_attribute!(product, pl_details, attributes)
    merge_pl_variants_union!(pl_details, attributes) if pl_details[:variants].present?

    # included_products — только из модалки набора на PL (см. PlDetailsFetcher), не смешиваем с set_items.
    merge_included_products_attribute!(product, pl_details, attributes)

    if pl_details[:videos].present? && attributes[:videos].blank?
      attributes[:videos] = pl_details[:videos]
    end

    if pl_details[:manuals].present? && attributes[:manuals].blank?
      attributes[:manuals] = download_documents(pl_details[:manuals], product.sku)
    end

    if pl_details[:assembly_documents].present? && attributes[:assembly_documents].blank?
      attributes[:assembly_documents] = download_documents(pl_details[:assembly_documents], product.sku)
    end

    if attributes[:small_desc_name].blank? && pl_details[:small_desc_name].present?
      attributes[:small_desc_name] = pl_details[:small_desc_name]
    end
  end

  def pl_product_url(product)
    sku_token = pip_url_token(product.sku)
    url_token = pip_url_token_from_pip_url(product.url)
    item_token = pip_url_token(product.item_no)

    # The source IKEA URL is authoritative: it distinguishes a real set SKU
    # (`s29545213`) from a component whose local listing alias happens to have
    # an `s` prefix (`s60489549`).
    return "https://www.ikea.com/pl/pl/p/-#{url_token}/" if url_token.present?

    # IncludedProductsBootstrapService enriches child articles with this flag.
    # Those children use their plain item number even when the listing alias
    # stored in Product#sku starts with `s`.
    return "https://www.ikea.com/pl/pl/p/-#{item_token}/" if @bundle_component && item_token.present?

    # Combo/set SKUs must keep the leading `s` in IKEA PIP URLs.
    # Example: /p/-s29545213/. Article-only URLs like /p/-29545213/
    # may open the wrong page or miss the full included-products modal.
    return "https://www.ikea.com/pl/pl/p/-#{sku_token}/" if set_sku_token?(sku_token)
    return "https://www.ikea.com/pl/pl/p/-#{item_token}/" if item_token.present?
    return "https://www.ikea.com/pl/pl/p/-#{sku_token}/" if sku_token.present?

    u = product.url.to_s
    return u if u.include?("/pl/pl/")
    u.gsub(%r{/lt/ru/}, "/pl/pl/").presence
  end

  def pip_url_token(value)
    value.to_s.gsub(/[^0-9a-z]/i, "").downcase.presence
  end

  def set_sku_token?(token)
    token.to_s.match?(/\As\d{8}\z/)
  end

  def pip_url_token_from_pip_url(url)
    url.to_s.downcase[/-(s?\d{8})(?:[\/?#]|$)/, 1].presence
  end

  def set_sku_from_pip_url(url)
    token = pip_url_token_from_pip_url(url)
    token if set_sku_token?(token)
  end

  def lt_product_url(product)
    # 1. Пробуем артикул из SKU (самый надежный способ для LT)
    match = product.sku.to_s.match(/(\d{8})/)
    sku_article = match ? match[1] : nil
    
    # 2. Пробуем item_no из БД
    db_article = product.item_no.to_s.gsub(/[^0-9a-z]/i, "").presence
    
    # Собираем список кандидатов для проверки
    articles = [sku_article, db_article].compact.uniq
    
    articles.each do |article|
      url = "https://www.ikea.com/lt/ru/p/-#{article}/"
      # Проверяем доступность страницы через быстрый HEAD запрос или простой GET
      # Но так как мы в сервисе, который будет вызван позже, мы просто возвращаем первый валидный паттерн
      # Улучшение: если мы здесь, значит мы хотим LT URL.
      return url
    end

    # 3. Fallback на URL из базы, если он литовский
    u = product.url.to_s
    return u if u.include?("/lt/ru/")
    nil
  end

  def fetch_details_with_optional_headless(url, scope_sku: nil)
    light = PlDetailsFetcher.fetch(url, use_headless: false, scope_sku: scope_sku) || {}

    if pl_headless_enabled? && pl_fetch_needs_headless?(light)
      reason =
        if pl_included_products_need_headless?(light)
          "included_products sheet"
        else
          "incomplete modal"
        end
      Rails.logger.info "ExtendedAttributesFetchService: #{reason} for #{url} -> headless"
      headless = fetch_headless_details_with_retries(url, scope_sku: scope_sku)
      light = merge_pl_headless_fetch(light, headless) if headless.present?
    end

    strip_pl_fetch_metadata!(light)
  end

  def apply_lt_descriptive(lt_details, attributes)
    if lt_details[:name].present?
      attributes[:name] = lt_details[:name]
      attributes[:name_ru] = lt_details[:name] if Product.column_names.include?("name_ru")
    end
    if lt_details[:small_desc_name].present? && attributes[:small_desc_name].blank?
      attributes[:small_desc_name] = lt_details[:small_desc_name]
    end
    if lt_details[:description].present? && attributes[:content].blank?
      attributes[:content] = lt_details[:description]
    end
    if lt_details[:short_description].present? && attributes[:short_description].blank?
      attributes[:short_description] = lt_details[:short_description]
    end

    if lt_details[:materials].present? && attributes[:materials].blank?
      attributes[:materials] =
        lt_details[:materials].is_a?(Array) ? lt_details[:materials].join("\n") : lt_details[:materials]
    end

    attributes[:features] = lt_details[:features] if lt_details[:features].present? && attributes[:features].blank?
    if lt_details[:care_instructions].present? && attributes[:care_instructions].blank?
      attributes[:care_instructions] = lt_details[:care_instructions]
    end
    if lt_details[:environmental_info].present? && attributes[:environmental_info].blank?
      attributes[:environmental_info] = lt_details[:environmental_info]
    end
    attributes[:designer] = lt_details[:designer] if lt_details[:designer].present? && attributes[:designer].blank?
    attributes[:safety_info] = lt_details[:safety_info] if lt_details[:safety_info].present? && attributes[:safety_info].blank?
    attributes[:good_to_know] = lt_details[:good_to_know] if lt_details[:good_to_know].present? && attributes[:good_to_know].blank?
    attributes[:translated] = true
  end

  def apply_pl_descriptive(pl_details, attributes)
    if pl_details[:name].present?
      attributes[:name] = pl_details[:name]
      attributes[:name_ru] = pl_details[:name]
    end
    if pl_details[:description].present? && attributes[:content].blank?
      attributes[:content] = pl_details[:description]
    end
    if pl_details[:short_description].present? && attributes[:short_description].blank?
      attributes[:short_description] = pl_details[:short_description]
    end

    if pl_details[:materials].present? && attributes[:materials].blank?
      attributes[:materials] =
        pl_details[:materials].is_a?(Array) ? Array(pl_details[:materials]).join("\n") : pl_details[:materials]
    end

    attributes[:features] = pl_details[:features] if pl_details[:features].present? && attributes[:features].blank?
    if pl_details[:care_instructions].present? && attributes[:care_instructions].blank?
      attributes[:care_instructions] = pl_details[:care_instructions]
    end
    if pl_details[:environmental_info].present? && attributes[:environmental_info].blank?
      attributes[:environmental_info] = pl_details[:environmental_info]
    end
    attributes[:designer] = pl_details[:designer] if pl_details[:designer].present? && attributes[:designer].blank?
    attributes[:safety_info] = pl_details[:safety_info] if pl_details[:safety_info].present? && attributes[:safety_info].blank?
    attributes[:good_to_know] = pl_details[:good_to_know] if pl_details[:good_to_know].present? && attributes[:good_to_know].blank?
    if pl_details[:small_desc_name].present? && attributes[:small_desc_name].blank?
      attributes[:small_desc_name] = pl_details[:small_desc_name]
    end
  end

  def merge_pl_structural_and_commerce(product, pl_details, attributes)
    reconcile_pl_scoped_product_images!(product, pl_details, attributes)

    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      attributes[key] = pl_details[key] if pl_details[key].present?
    end

    attributes[:set_items] = pl_details[:set_items] if pl_details[:set_items]
    merge_related_products_attribute!(product, pl_details, attributes)
    merge_pl_variants_union!(pl_details, attributes) if pl_details[:variants].present?

    merge_included_products_attribute!(product, pl_details, attributes)

    attributes[:videos] = pl_details[:videos] if pl_details[:videos]
    if pl_details[:manuals].present?
      attributes[:manuals] = download_documents(pl_details[:manuals], product.sku)
    end
    if pl_details[:assembly_documents].present?
      attributes[:assembly_documents] = download_documents(pl_details[:assembly_documents], product.sku)
    end

    assign_valid_pl_price!(pl_details, attributes)

    update_quantity(product, pl_details, attributes)
  end

  def supplement_from_ikea_lt_legacy(product, attributes)
    return unless product.item_no.present?
    return if attributes[:materials].present? && attributes[:content].present? && attributes[:small_desc_name].present?

    lt_details = LtDetailsFetcher.fetch(product.item_no)
    return unless lt_details.present? && lt_details[:translated]

    if lt_details[:small_desc_name].present? && attributes[:small_desc_name].blank?
      attributes[:small_desc_name] = lt_details[:small_desc_name]
    end

    %i[materials good_to_know content].each do |field|
      next if attributes[field].present?
      val = lt_details[field] || lt_details["#{field == :content ? :details : field}_text".to_sym]
      next if val.blank?
      attributes[field] = val
      attributes["#{field}_ru".to_sym] = val
    end

    if lt_details[:material_text].present?
      attributes[:material_info] = lt_details[:material_text]
      attributes[:material_info_ru] = lt_details[:material_text]
    end
    if lt_details[:good_text].present?
      attributes[:good_info] = lt_details[:good_text]
      attributes[:good_info_ru] = lt_details[:good_text]
    end

    attributes[:translated] = true
  rescue StandardError => e
    Rails.logger.warn "ExtendedAttributesFetchService: ikea.lt supplement failed #{product.sku}: #{e.message}"
  end

  def assign_product_details_modal_to_full_attributes!(product, pl_details, lt_details, use_lt, attributes)
    snap =
      if use_lt && lt_details[:product_details_modal].present?
        lt_details[:product_details_modal]
      elsif pl_details[:product_details_modal].present?
        pl_details[:product_details_modal]
      end
    return if snap.blank?
    return unless product.respond_to?(:full_attributes=)

    snap_s = snap.is_a?(Hash) ? snap.deep_stringify_keys : snap
    existing = attributes[:full_attributes].presence || product.full_attributes
    base = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
    base["product_details_modal"] = snap_s
    base["product_details_modal_extracted_at"] = Time.current.iso8601
    attributes[:full_attributes] = base
  end

  def assign_measurements_modal_to_full_attributes!(product, pl_details, lt_details, use_lt, attributes)
    snap = pick_measurements_modal_snapshot(pl_details, lt_details, use_lt)
    return if snap.blank?
    return unless product.respond_to?(:full_attributes=)

    snap_s = snap.is_a?(Hash) ? snap.deep_stringify_keys : snap
    existing = attributes[:full_attributes].presence || product.full_attributes
    base = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
    base["measurements_modal"] = snap_s
    base["measurements_modal_extracted_at"] = Time.current.iso8601
    attributes[:full_attributes] = base
  end

  # LT-модалка раньше перекрывала PL целиком: на LT часто нет полной ВГХ упаковки, на PL — есть.
  # Тогда подставляем только блок packages (и заметку о числе упаковок) из PL, оставляя product_measurements с LT.
  def pick_measurements_modal_snapshot(pl_details, lt_details, use_lt)
    pl_mm = pl_details[:measurements_modal]
    lt_mm = lt_details[:measurements_modal]

    if use_lt && lt_mm.present?
      merge_pl_packages_into_lt_when_lt_missing_packaging_dims(lt_mm, pl_mm)
    elsif pl_mm.present?
      pl_mm
    end
  end

  def merge_pl_packages_into_lt_when_lt_missing_packaging_dims(lt_mm, pl_mm)
    return lt_mm if pl_mm.blank?
    return lt_mm if Products::PackagingDimensionsStatus.modal_has_full_packaging_dimensions?(lt_mm)
    return lt_mm unless Products::PackagingDimensionsStatus.modal_has_full_packaging_dimensions?(pl_mm)

    lt = lt_mm.is_a?(Hash) ? lt_mm.deep_stringify_keys.deep_dup : {}
    pl = pl_mm.is_a?(Hash) ? pl_mm.deep_stringify_keys : {}
    pkgs = pl["packages"]
    return lt_mm if pkgs.blank?

    lt["packages"] = pkgs
    lt["number_of_packages"] = pl["number_of_packages"] if pl["number_of_packages"].present?
    lt["package_count_note"] = pl["package_count_note"] if pl["package_count_note"].present? && lt["package_count_note"].blank?
    lt
  end

  def assign_inferred_variant_type!(product, pl_details, attributes)
    return unless Product.column_names.include?("variant_type")

    inferred = pl_details[:variant_picker_types].to_s.strip.presence
    return if inferred.blank?
    return if product.variant_type.present?

    attributes[:variant_type] = inferred
  end

  def mirror_ru_for_lt_text!(attributes)
    return unless attributes[:translated]

    %i[short_description content materials features care_instructions environmental_info designer safety_info good_to_know dimensions].each do |f|
      next if attributes[f].blank?
      k = "#{f}_ru".to_sym
      attributes[k] = attributes[f] if attributes[k].blank?
    end
  end

  def merge_related_products_attribute!(product, details, attributes)
    return if details.blank?

    incoming = details[:related_products] || details["related_products"]
    incoming = Array(incoming).filter_map { |sku| normalize_related_product_sku(sku) }
    return if incoming.empty?

    current = parse_json_array(attributes[:related_products]).filter_map { |sku| normalize_related_product_sku(sku) }
    parent_article = normalize_related_product_sku(product&.sku).to_s.sub(/\As/i, "")

    merged = (current + incoming).uniq
    merged.reject! { |sku| sku.to_s.sub(/\As/i, "") == parent_article } if parent_article.present?

    attributes[:related_products] = merged if merged.any?
  end

  def normalize_related_product_sku(value)
    token = value.is_a?(Hash) ? (value["sku"] || value[:sku] || value["item_no"] || value[:item_no]) : value
    token = token.to_s.gsub(/[^0-9a-z]/i, "")
    return nil if token.blank?

    token if token.match?(/\A\d{8}\z/i) || token.match?(/\As\d{8}\z/i)
  end

  def pl_modal_fields_complete?(details)
    details.present? && details[:materials].present? && details[:care_instructions].present?
  end

  def pl_fetch_needs_headless?(details)
    !pl_modal_fields_complete?(details) || pl_included_products_need_headless?(details)
  end

  # Модалка «Elementy w zestawie» / «Что входит в комплект» — только после клика (PlDetailsFetcher).
  def pl_included_products_need_headless?(details)
    return false if details.blank?

    from_modal = details[:included_products_from_modal]
    from_modal = details["included_products_from_modal"] if from_modal.nil?
    return false if ActiveModel::Type::Boolean.new.cast(from_modal)

    flag = details[:included_sheet_needs_headless]
    flag = details["included_sheet_needs_headless"] if flag.nil?
    return false unless ActiveModel::Type::Boolean.new.cast(flag)

    # Частичный SSR-список не заменяет клик по «Elementy w zestawie» — headless всегда, если sheet в DOM.
    true
  end

  def strip_pl_fetch_metadata!(details)
    return {} if details.blank?

    details.except(
      :included_sheet_needs_headless, "included_sheet_needs_headless",
      :included_products_from_modal, "included_products_from_modal"
    )
  end

  def merge_pl_headless_fetch(light, headless)
    merged = headless.dup
    headless_included = normalize_included_articles(merged[:included_products])
    from_modal = merged[:included_products_from_modal] || merged["included_products_from_modal"]

    if ActiveModel::Type::Boolean.new.cast(from_modal) && headless_included.any?
      merged[:included_products] = (
        headless_included + normalize_included_articles(light[:included_products])
      ).uniq
    else
      combined = (headless_included + normalize_included_articles(light[:included_products])).compact.uniq
      merged[:included_products] = combined if combined.any?
    end
    merged
  end

  def normalize_included_articles(values)
    Products::ArticleNumber.normalize_list(values)
  end

  def merge_included_products_attribute!(product, pl_details, attributes)
    pl_list = reject_product_article_from_included(
      product,
      normalize_included_articles(pl_details[:included_products])
    )
    return if pl_list.empty?
  
    from_modal = pl_details[:included_products_from_modal] || pl_details["included_products_from_modal"]
  
    if ActiveModel::Type::Boolean.new.cast(from_modal)
      existing = normalize_included_articles(product.included_products)
      attributes[:included_products] = reject_product_article_from_included(product, existing + pl_list)
      return
    end
  
    existing = normalize_included_articles(product.included_products)
    merged = existing + pl_list + normalize_included_articles(attributes[:included_products])
    attributes[:included_products] = reject_product_article_from_included(product, merged)
  end
  
  def reject_product_article_from_included(product, list)
    product_tokens = [
      product.sku,
      product.item_no,
      set_sku_from_pip_url(product.url)
    ].compact.flat_map do |value|
      token = value.to_s.gsub(/[^0-9a-z]/i, "").downcase
      [token, token.sub(/\As/, "")]
    end.reject(&:blank?).uniq
  
    Products::ArticleNumber.normalize_list(list)
      .reject do |article|
        token = article.to_s.gsub(/[^0-9a-z]/i, "").downcase
        product_tokens.include?(token) || product_tokens.include?(token.sub(/\As/, ""))
      end
      .uniq
  end

  def pl_headless_enabled?
    %w[true 1 yes].include?(ENV.fetch("PL_FETCHER_ENABLE_HEADLESS", "true").to_s.downcase)
  end

  def fetch_headless_details_with_retries(url, scope_sku: nil)
    attempt = 0

    begin
      attempt += 1
      PlDetailsFetcher.fetch(url, use_headless: true, scope_sku: scope_sku) || {}
    rescue PlDetailsFetcher::HeadlessFetchError => e
      if attempt >= HEADLESS_FETCH_MAX_ATTEMPTS
        raise HeadlessRetriesExhaustedError,
              "headless retries exhausted after #{attempt} attempts: #{e.message}"
      end

      delay = HEADLESS_RETRY_DELAYS.fetch(attempt - 1, HEADLESS_RETRY_DELAYS.last)
      Rails.logger.warn(
        "ExtendedAttributesFetchService: headless retry #{attempt}/#{HEADLESS_FETCH_MAX_ATTEMPTS} " \
        "for #{url} in #{delay}s: #{e.message}"
      )
      sleep(delay)
      retry
    end
  end

  def assign_valid_pl_price!(pl_details, attributes)
    price = pl_details[:price]
    return unless Products::StockAvailability.sale_price?(price)

    attributes[:price] = price
  end

  def parse_json_array(val)
    return val if val.is_a?(Array)
    return [] if val.blank?
    JSON.parse(val)
  rescue JSON::ParserError
    []
  end

  # PL PIP часто даёт полную матрицу вариантов; LT/HTML — неполную. Объединяем SKU без дублей.
  def merge_pl_variants_union!(pl_details, attributes)
    return unless pl_details[:variants].present?

    pl_v = normalize_variants_payload(pl_details[:variants])
    return if pl_v.empty?

    cur_v = normalize_variants_payload(attributes[:variants])
    attributes[:variants] = (cur_v + pl_v).uniq { |x| x["sku"] }
  end

  def normalize_variants_payload(raw)
    Array(raw).filter_map do |entry|
      case entry
      when Hash
        sku = entry["sku"] || entry[:sku] ||
              entry["itemNo"] || entry[:itemNo] ||
              entry["itemNoGlobal"] || entry[:itemNoGlobal] ||
              entry["visibleItemNo"] || entry[:visibleItemNo] ||
              entry["articleNumber"] || entry[:articleNumber] ||
              entry["id"] || entry[:id] || entry["value"] || entry[:value]
        if sku.blank? && (entry["pipUrl"].present? || entry[:pipUrl].present?)
          url = (entry["pipUrl"] || entry[:pipUrl]).to_s
          m = url.match(/-([a-z0-9]{8,9})\/?$/i)
          sku = m[1] if m
        end
        sku_s = sku.to_s.gsub(/[^0-9a-z]/i, "").downcase
        next if sku_s.blank?
        next unless sku_s.match?(/\A\d{8}\z/) || sku_s.match?(/\As\d{8}\z/)
        { "sku" => sku_s }
      else
        sku_s = entry.to_s.strip
        next if sku_s.blank?
        { "sku" => sku_s }
      end
    end.uniq { |v| v["sku"] }
  end

  def download_documents(documents, sku)
    dedupe_document_rows(documents).filter_map do |doc|
      url = doc.is_a?(Hash) ? (doc[:url] || doc["url"] || doc["Link"] || doc["href"]) : doc.to_s
      title = doc.is_a?(Hash) ? (doc[:title] || doc["title"] || doc["Tytuł"] || doc["Tytul"] || doc[:name] || doc["name"]) : nil
      next if url.blank?
      if @skip_document_download
        { "title" => title, "url" => url }.compact
      else
        local_url = DocumentDownloader.download(url, product_sku: sku)
        { "title" => title, "url" => url, "local_url" => local_url }.compact
      end
    end
  end

  def dedupe_document_rows(documents)
    seen = {}
    Array(documents).each_with_object([]) do |doc, acc|
      url = doc.is_a?(Hash) ? (doc[:url] || doc["url"] || doc["Link"] || doc["href"]) : doc.to_s
      url = url.to_s.strip
      next if url.blank?

      key = PlDetailsFetcher.canonical_document_url_for_dedupe(url)
      next if seen[key]

      seen[key] = true
      acc << doc
    end
  end

  def update_quantity(product, pl_details, attributes)
    if product.item_no.present?
      begin
        availability_data = IkeaApiService.check_availability([product.item_no])
        availability = availability_data[product.item_no.to_s] || availability_data[product.item_no.to_i] || availability_data[product.item_no]
        if availability && availability[:quantity].present?
          attributes[:quantity] = availability[:quantity]
          attributes[:is_parcel] = availability[:is_parcel] if availability.key?(:is_parcel)
          return
        end
      rescue StandardError => e
        Rails.logger.warn "ExtendedAttributesFetchService: API availability failed #{product.sku}: #{e.message}"
      end
    end

    if pl_details.dig(:availability, :quantity).present?
      attributes[:quantity] = pl_details[:availability][:quantity]
    end
  end

  POLISH_TRANSLATABLE_FIELDS = %i[
    small_desc_name short_description content materials features
    care_instructions environmental_info designer safety_info good_to_know
  ].freeze

  # Польский текст → русский в основной колонке (как с LT) и в *_ru при наличии.
  def apply_russian_translations_for_polish_fields!(product, attributes, force: false)
    translate_name_ru_if_needed!(product, attributes)

    POLISH_TRANSLATABLE_FIELDS.each do |field|
      next unless Product.column_names.include?(field.to_s)

      source_text = attributes[field].presence || product.read_attribute(field)
      next if source_text.blank?

      plain = source_text.is_a?(Array) ? source_text.join("\n") : source_text.to_s
      needs_translation = force ? !TranslationService.predominantly_russian?(plain) : TranslationService.needs_polish_to_russian_translation?(plain)
      next unless needs_translation

      translated = TranslationService.translate(plain, context: "product_#{field}")
      next if translated.blank? || TranslationService.invalid_translation?(translated, plain)

      attributes[field] = translated
      field_ru = "#{field}_ru".to_sym
      attributes[field_ru] = translated if Product.column_names.include?(field_ru.to_s)
      attributes[:translated] = true
      attributes[:ai_translated] = true
    end
  end

  def translate_name_ru_if_needed!(product, attributes)
    return unless Product.column_names.include?("name_ru")

    src_name = (attributes[:name] || product.name).to_s.strip
    return if src_name.blank?
    return if src_name.match?(/[а-яА-ЯЁё]/)

    existing_ru = attributes[:name_ru].presence || product.read_attribute(:name_ru).to_s
    return if existing_ru.present? && existing_ru.match?(/[а-яА-ЯЁё]/)
    return unless attributes[:name_ru].blank? && product.read_attribute(:name_ru).blank?
    return unless TranslationService.needs_polish_to_russian_translation?(src_name)

    t = TranslationService.translate(src_name, context: "product_name")
    attributes[:name_ru] = t if t.present? && !TranslationService.invalid_translation?(t, src_name)
  end

  # Совместимость с RecoverBrokenProductTranslationsJob и force_ai_translation.
  def translate_all_fields_via_ai!(product, attributes)
    apply_russian_translations_for_polish_fields!(product, attributes, force: true)
  end

  # API «Материал и уход» читает product_details_modal в full_attributes — переводим снимок PL.
  def translate_polish_in_stored_product_details_modal!(attributes, force: false)
    fa = attributes[:full_attributes]
    return unless fa.is_a?(Hash)

    pdm = fa["product_details_modal"] || fa[:product_details_modal]
    return if pdm.blank?

    pdm = pdm.deep_dup.deep_stringify_keys
    changed = false

    Array(pdm["intro_paragraphs"]).map! do |para|
      t = translate_polish_fragment(para, force: force, context: "modal_intro")
      changed = true if t != para.to_s
      t
    end

    sec = material_and_care_section(pdm)
    if sec.present?
      Array(sec["material_blocks"]).each do |blk|
        next unless blk.is_a?(Hash)

        if blk["subheader"].present?
          old = blk["subheader"].to_s
          blk["subheader"] = translate_polish_fragment(old, force: force, context: "modal_material_subheader")
          changed = true if blk["subheader"] != old
        end

        Array(blk["pairs"]).each do |pair|
          next unless pair.is_a?(Hash)

          %w[term definition].each do |key|
            next if pair[key].blank?

            old = pair[key].to_s
            pair[key] = translate_polish_fragment(old, force: force, context: "modal_material_#{key}")
            changed = true if pair[key] != old
          end
        end
      end

      Array(sec["care_blocks"]).each do |blk|
        next unless blk.is_a?(Hash)

        if blk["header"].present?
          old = blk["header"].to_s
          blk["header"] = translate_polish_fragment(old, force: force, context: "modal_care_header")
          changed = true if blk["header"] != old
        end

        blk["lines"] = Array(blk["lines"]).map do |ln|
          old = ln.to_s
          t = translate_polish_fragment(old, force: force, context: "modal_care_line")
          changed = true if t != old
          t
        end
      end
    end

    return unless changed

    base = fa.deep_dup.deep_stringify_keys
    base["product_details_modal"] = pdm
    attributes[:full_attributes] = base
    attributes[:translated] = true
    attributes[:ai_translated] = true
  end

  def translate_polish_in_detailed_info!(attributes, force: false)
    fa = attributes[:full_attributes]
    return unless fa.is_a?(Hash)

    di = fa["detailed_info"] || fa[:detailed_info]
    return unless di.is_a?(Hash)

    base = fa.deep_dup.deep_stringify_keys
    info = (base["detailed_info"] || {}).deep_stringify_keys
    changed = false

    raw = info["Материал и уход"]
    if raw.is_a?(Hash)
      info["Материал и уход"] = raw.transform_values do |v|
        t = translate_polish_fragment(v, force: force, context: "detailed_info_materials")
        changed = true if t != v.to_s
        t
      end
    elsif raw.present?
      t = translate_polish_fragment(raw, force: force, context: "detailed_info_materials")
      if t != raw.to_s
        info["Материал и уход"] = t
        changed = true
      end
    end

    return unless changed

    base["detailed_info"] = info
    attributes[:full_attributes] = base
    attributes[:translated] = true
    attributes[:ai_translated] = true
  end

  def sync_materials_and_care_from_product_details_modal!(attributes)
    fa = attributes[:full_attributes]
    return unless fa.is_a?(Hash)

    pdm = fa["product_details_modal"] || fa[:product_details_modal]
    return if pdm.blank?

    h = ProductSerializer.materials_hash_from_product_details_modal(pdm)
    if h.present?
      joined = h.map { |k, v| "#{k}: #{v}".strip }.reject(&:blank?).join("\n")
      if joined.present?
        attributes[:materials] = joined
        assign_translated_column_mirror!(:materials, joined, attributes)
      end
    end

    care_text = care_instructions_text_from_product_details_modal(pdm)
    return if care_text.blank?

    attributes[:care_instructions] = care_text
    assign_translated_column_mirror!(:care_instructions, care_text, attributes)
  end

  def material_and_care_section(pdm)
    Array(pdm["accordion_sections"]).find do |s|
      s.is_a?(Hash) && s["id"].to_s.include?("material-and-care")
    end
  end

  def care_instructions_text_from_product_details_modal(pdm)
    sec = material_and_care_section(pdm.is_a?(Hash) ? pdm.deep_stringify_keys : pdm)
    return nil unless sec

    lines = []
    Array(sec["care_blocks"]).each do |blk|
      next unless blk.is_a?(Hash)

      Array(blk["lines"]).each do |ln|
        s = ln.to_s.strip
        lines << s if s.present?
      end
    end
    lines.join("\n").presence
  end

  def translate_polish_fragment(text, force:, context:)
    s = text.to_s
    return s if s.blank?

    needs = force ? !TranslationService.predominantly_russian?(s) : TranslationService.needs_polish_to_russian_translation?(s)
    return s unless needs

    translated = TranslationService.translate(s, context: context)
    return s if translated.blank? || TranslationService.invalid_translation?(translated, s)

    translated
  end

  def assign_translated_column_mirror!(field, value, attributes)
    ru_key = "#{field}_ru".to_sym
    attributes[ru_key] = value if Product.column_names.include?(ru_key.to_s)
  end
end
