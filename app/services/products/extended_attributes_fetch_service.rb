# frozen_string_literal: true

# Расширенные поля товара из витрин IKEA.
#
# Приоритет для товаров LT (ikea.com/lt/ru или строка results_jsonl с витрины LT):
#   — описания, материалы, характеристики, ВГХ (вес, габариты, объём), картинки — с LT;
#   — опционально строка JSONL (ключ "Подробная информация о товаре") — полный снимок с LT-парсера;
#   — цена и остаток — с PL (zł / API) и API наличия;
#   — варианты: списки SKU с LT и с PL объединяются (PL PIP часто даёт itemNo / полную матрицу).
#
# Связи наборов / сопутствующие SKU и документы без LT — дополняются с PL, если пусто.
class Products::ExtendedAttributesFetchService
  def self.fetch_for_product(product, results_jsonl_row: nil)
    new.fetch(product, results_jsonl_row: results_jsonl_row)
  end

  def fetch(product, results_jsonl_row: nil)
    pl_url = pl_product_url(product)
    return { updated: false } if pl_url.blank?

    pl_details = fetch_details_with_optional_headless(pl_url)
    return { updated: false } if pl_details.blank?

    lt_url = lt_product_url(product)
    use_lt_descriptive = lt_url.present? && lt_url != pl_url
    lt_details = use_lt_descriptive ? fetch_details_with_optional_headless(lt_url) : {}

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

    supplement_from_ikea_lt_legacy(product, attributes) if use_lt_descriptive && !jsonl_applied

    assign_product_details_modal_to_full_attributes!(product, pl_details, lt_details, use_lt_descriptive, attributes)
    assign_measurements_modal_to_full_attributes!(product, pl_details, lt_details, use_lt_descriptive, attributes)
    assign_inferred_variant_type!(product, pl_details, attributes)

    mirror_ru_for_lt_text!(attributes)
    translate_remaining_fields(product, attributes)

    strip_nil_overwrites_from_product!(product, attributes)

    if attributes.any?
      product.update!(attributes)
      { updated: true }
    else
      { updated: false }
    end
  end

  private

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

  def supplement_lt_descriptive_gaps(lt_details, attributes)
    attributes[:name_ru] = lt_details[:name] if attributes[:name_ru].blank? && lt_details[:name].present?
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

    if lt_details[:included_products].present?
      existing = Array(attributes[:included_products]).presence || Array(product.included_products).map(&:to_s)
      attributes[:included_products] = (existing + Array(lt_details[:included_products]).map(&:to_s)).compact.uniq
    end

    if lt_details[:variants].present? && attributes[:variants].blank?
      attributes[:variants] = normalize_variants_payload(lt_details[:variants])
    end
  end

  def merge_pl_with_lt_priority(product, pl_details, attributes)
    attributes[:price] = pl_details[:price] if pl_details[:price].present?
    update_quantity(product, pl_details, attributes)

    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      attributes[key] = pl_details[key] if pl_details[key].present? && attributes[key].blank?
    end

    if pl_details[:images].present? && pl_details[:images].is_a?(Array)
      pl_images = pl_details[:images].map(&:to_s).map(&:strip).reject(&:blank?).uniq
      base = parse_json_array(product.images)
      merged_imgs = (base + pl_images).uniq
      attributes[:images] = merged_imgs if merged_imgs != base
    end

    attributes[:set_items] = pl_details[:set_items] if pl_details[:set_items].present? && attributes[:set_items].blank?
    attributes[:bundle_items] = pl_details[:bundle_items] if pl_details[:bundle_items].present? && attributes[:bundle_items].blank?
    if pl_details[:related_products].present?
      merged_rp = (parse_json_array(attributes[:related_products]) + Array(pl_details[:related_products]).map(&:to_s)).compact.uniq
      attributes[:related_products] = merged_rp if merged_rp.any?
    end
    merge_pl_variants_union!(pl_details, attributes) if pl_details[:variants].present?

    combined_included = Array(pl_details[:set_items]).map(&:to_s) + Array(pl_details[:bundle_items]).map(&:to_s)
    if combined_included.any?
      existing = Array(product.included_products).map(&:to_s)
      merged = (existing + combined_included + Array(attributes[:included_products]).map(&:to_s)).compact.uniq
      attributes[:included_products] = merged
    end

    if pl_details[:videos].present? && attributes[:videos].blank?
      attributes[:videos] = pl_details[:videos]
    end

    if pl_details[:manuals].present? && attributes[:manuals].blank?
      attributes[:manuals] = download_documents(pl_details[:manuals], product.sku)
    end

    if pl_details[:assembly_documents].present? && attributes[:assembly_documents].blank?
      attributes[:assembly_documents] = download_documents(pl_details[:assembly_documents], product.sku)
    end
  end

  def pl_product_url(product)
    article = product.item_no.to_s.gsub(/[^0-9a-z]/i, "").presence
    return "https://www.ikea.com/pl/pl/p/-#{article}/" if article.present?

    u = product.url.to_s
    return u if u.include?("/pl/pl/")
    u.gsub(%r{/lt/ru/}, "/pl/pl/").presence
  end

  def lt_product_url(product)
    article = product.item_no.to_s.gsub(/[^0-9a-z]/i, "").presence
    return "https://www.ikea.com/lt/ru/p/-#{article}/" if article.present?

    u = product.url.to_s
    return u if u.include?("/lt/ru/")
    nil
  end

  def fetch_details_with_optional_headless(url)
    details = PlDetailsFetcher.fetch(url, use_headless: false) || {}
    if !pl_modal_fields_complete?(details) && pl_headless_enabled?
      Rails.logger.info "ExtendedAttributesFetchService: incomplete modal for #{url} -> headless"
      headless = PlDetailsFetcher.fetch(url, use_headless: true)
      details = headless if headless.present?
    end
    details
  end

  def apply_lt_descriptive(lt_details, attributes)
    if lt_details[:name].present? && attributes[:name_ru].blank?
      attributes[:name_ru] = lt_details[:name]
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
  end

  def merge_pl_structural_and_commerce(product, pl_details, attributes)
    if pl_details[:images].present? && pl_details[:images].is_a?(Array) && pl_details[:images].any?
      all_images = pl_details[:images].map(&:to_s).map(&:strip).reject(&:blank?).uniq
      existing_images = parse_json_array(product.images)
      merged = (existing_images + all_images).uniq
      attributes[:images] = merged if merged != existing_images
    end

    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      attributes[key] = pl_details[key] if pl_details[key].present?
    end

    attributes[:set_items] = pl_details[:set_items] if pl_details[:set_items]
    attributes[:bundle_items] = pl_details[:bundle_items] if pl_details[:bundle_items]
    if pl_details[:related_products].present?
      merged_rp = (parse_json_array(attributes[:related_products]) + Array(pl_details[:related_products]).map(&:to_s)).compact.uniq
      attributes[:related_products] = merged_rp if merged_rp.any?
    end
    merge_pl_variants_union!(pl_details, attributes) if pl_details[:variants].present?

    combined_included = Array(pl_details[:set_items]).map(&:to_s) + Array(pl_details[:bundle_items]).map(&:to_s)
    if combined_included.any?
      existing = Array(product.included_products).map(&:to_s)
      merged = (existing + combined_included + Array(attributes[:included_products]).map(&:to_s)).compact.uniq
      attributes[:included_products] = merged
    end

    attributes[:videos] = pl_details[:videos] if pl_details[:videos]
    if pl_details[:manuals].present?
      attributes[:manuals] = download_documents(pl_details[:manuals], product.sku)
    end
    if pl_details[:assembly_documents].present?
      attributes[:assembly_documents] = download_documents(pl_details[:assembly_documents], product.sku)
    end

    attributes[:price] = pl_details[:price] if pl_details[:price].present?

    update_quantity(product, pl_details, attributes)
  end

  def supplement_from_ikea_lt_legacy(product, attributes)
    return unless product.item_no.present?
    return if attributes[:materials].present? && attributes[:content].present? && attributes[:name_ru].present?

    lt_details = LtDetailsFetcher.fetch(product.item_no)
    return unless lt_details.present? && lt_details[:translated]

    attributes[:name_ru] = lt_details[:name] if attributes[:name_ru].blank? && lt_details[:name].present?

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
    snap =
      if use_lt && lt_details[:measurements_modal].present?
        lt_details[:measurements_modal]
      elsif pl_details[:measurements_modal].present?
        pl_details[:measurements_modal]
      end
    return if snap.blank?
    return unless product.respond_to?(:full_attributes=)

    snap_s = snap.is_a?(Hash) ? snap.deep_stringify_keys : snap
    existing = attributes[:full_attributes].presence || product.full_attributes
    base = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
    base["measurements_modal"] = snap_s
    base["measurements_modal_extracted_at"] = Time.current.iso8601
    attributes[:full_attributes] = base
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

  def pl_modal_fields_complete?(details)
    details.present? && details[:materials].present? && details[:care_instructions].present?
  end

  def pl_headless_enabled?
    %w[true 1 yes].include?(ENV.fetch("PL_FETCHER_ENABLE_HEADLESS", "true").to_s.downcase)
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
      local_url = DocumentDownloader.download(url, product_sku: sku)
      { "title" => title, "url" => url, "local_url" => local_url }.compact
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

  def translate_remaining_fields(product, attributes)
    fields = %i[name short_description content materials features care_instructions environmental_info designer safety_info good_to_know]

    fields.each do |field|
      field_ru = "#{field}_ru".to_sym
      source_text = attributes[field] || product.read_attribute(field)
      next if source_text.blank?
      next unless attributes[field_ru].blank? && (product.read_attribute(field_ru).blank? || product.read_attribute(field_ru) == product.read_attribute(field))

      translated = TranslationService.translate(source_text.is_a?(Array) ? source_text.join("\n") : source_text)
      attributes[field_ru] = translated if translated.present? && !TranslationService.invalid_translation?(translated, source_text)
    end
  end
end
