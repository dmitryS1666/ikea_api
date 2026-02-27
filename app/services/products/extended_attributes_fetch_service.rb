class Products::ExtendedAttributesFetchService
  def self.fetch_for_product(product)
    new.fetch(product)
  end

  def fetch(product)
    return { updated: false } unless product.url.present?
    
    Rails.logger.info "ExtendedAttributesFetchService: Fetching for #{product.sku} from #{product.url}"

    # Используем PlDetailsFetcher для получения данных с сайта IKEA PL
    pl_details = PlDetailsFetcher.fetch(product.url, use_headless: false) || {}

    if !pl_modal_fields_complete?(pl_details) && pl_headless_enabled?
      Rails.logger.info "ExtendedAttributesFetchService: PL fetch without headless incomplete -> trying headless"
      headless_details = PlDetailsFetcher.fetch(product.url, use_headless: true)
      pl_details = headless_details if headless_details.present?
    end

    return { updated: false } unless pl_details.present?
    
    attributes = {}
    
    # 1. Изображения
    if pl_details[:images].present? && pl_details[:images].is_a?(Array) && pl_details[:images].any?
      existing_images = parse_json_array(product.images)
      all_images = (existing_images + pl_details[:images]).compact.uniq
      attributes[:images] = all_images if all_images.length > existing_images.length
    end
    
    # 2. Вес и размеры
    %i[weight net_weight package_volume package_dimensions dimensions collection].each do |key|
      attributes[key] = pl_details[key] if pl_details[key]
    end
    
    # 3. Описания
    attributes[:content] = pl_details[:description] if pl_details[:description].present?
    attributes[:short_description] = pl_details[:short_description] if pl_details[:short_description].present?
    
    # 4. Материалы и характеристики
    attributes[:materials] = Array(pl_details[:materials]).join("\n") if pl_details[:materials].present?
    attributes[:features] = pl_details[:features] if pl_details[:features].present?
    attributes[:care_instructions] = pl_details[:care_instructions] if pl_details[:care_instructions].present?
    attributes[:environmental_info] = pl_details[:environmental_info] if pl_details[:environmental_info].present?
    
    # 5. Связанные продукты
    attributes[:set_items] = pl_details[:set_items] if pl_details[:set_items]
    attributes[:bundle_items] = pl_details[:bundle_items] if pl_details[:bundle_items]
    attributes[:related_products] = pl_details[:related_products] if pl_details[:related_products].present?
    
    # 6. Документы
    attributes[:videos] = pl_details[:videos] if pl_details[:videos]
    attributes[:manuals] = download_documents(pl_details[:manuals], product.sku) if pl_details[:manuals].present?
    attributes[:assembly_documents] = download_documents(pl_details[:assembly_documents], product.sku) if pl_details[:assembly_documents].present?
    
    # 7. Прочие атрибуты
    attributes[:designer] = pl_details[:designer] if pl_details[:designer]
    attributes[:safety_info] = pl_details[:safety_info] if pl_details[:safety_info]
    attributes[:good_to_know] = pl_details[:good_to_know] if pl_details[:good_to_know]
    attributes[:price] = pl_details[:price] if product.price.blank? && pl_details[:price]
    
    # 8. Наличие (quantity)
    update_quantity(product, pl_details, attributes)
    
    # 9. Данные из LT (литовского сайта - переводы)
    fetch_lt_details(product, attributes)
    
    # 10. Перевод оставшихся полей
    translate_remaining_fields(product, attributes)
    
    # Сохраняем результат
    if attributes.any?
      product.update!(attributes)
      { updated: true }
    else
      { updated: false }
    end
  end

  private

  def pl_modal_fields_complete?(details)
    details.present? && details[:materials].present? && details[:care_instructions].present?
  end

  def pl_headless_enabled?
    %w[true 1 yes].include?(ENV.fetch('PL_FETCHER_ENABLE_HEADLESS', 'true').to_s.downcase)
  end

  def parse_json_array(val)
    return val if val.is_a?(Array)
    return [] if val.blank?
    JSON.parse(val) rescue []
  end

  def download_documents(documents, sku)
    Array(documents).filter_map do |doc|
      url = doc.is_a?(Hash) ? (doc[:url] || doc["url"] || doc["Link"] || doc["href"]) : doc.to_s
      title = doc.is_a?(Hash) ? (doc[:title] || doc["title"] || doc["Tytuł"] || doc["Tytul"] || doc[:name] || doc["name"]) : nil
      next if url.blank?
      local_url = DocumentDownloader.download(url, product_sku: sku)
      { "title" => title, "url" => url, "local_url" => local_url }.compact
    end
  end

  def update_quantity(product, pl_details, attributes)
    # Сначала пробуем API
    if product.item_no.present?
      begin
        availability_data = IkeaApiService.check_availability([product.item_no])
        availability = availability_data[product.item_no.to_s] || availability_data[product.item_no.to_i] || availability_data[product.item_no]
        if availability && availability[:quantity].present?
          attributes[:quantity] = availability[:quantity]
          attributes[:is_parcel] = availability[:is_parcel] if availability.key?(:is_parcel)
          return
        end
      rescue => e
        Rails.logger.warn "ExtendedAttributesFetchService: API availability check failed for #{product.sku}: #{e.message}"
      end
    end

    # Fallback на данные из HTML
    if pl_details.dig(:availability, :quantity).present?
      attributes[:quantity] = pl_details[:availability][:quantity]
    end
  end

  def fetch_lt_details(product, attributes)
    return unless product.item_no.present?
    
    lt_details = LtDetailsFetcher.fetch(product.item_no) rescue nil
    return unless lt_details.present? && lt_details[:translated]

    attributes[:name_ru] = lt_details[:name] if lt_details[:name].present?
    
    %i[materials good_to_know content].each do |field|
      val = lt_details[field] || lt_details["#{field == :content ? :details : field}_text".to_sym]
      if val.present?
        attributes[field] = val
        attributes["#{field}_ru".to_sym] = val
      end
    end
    
    # Совместимость со старыми полями
    attributes[:material_info] = lt_details[:material_text] if lt_details[:material_text].present?
    attributes[:material_info_ru] = lt_details[:material_text] if lt_details[:material_text].present?
    attributes[:good_info] = lt_details[:good_text] if lt_details[:good_text].present?
    attributes[:good_info_ru] = lt_details[:good_text] if lt_details[:good_text].present?
    
    attributes[:translated] = true
  end

  def translate_remaining_fields(product, attributes)
    fields = %i[name short_description content materials features care_instructions environmental_info designer safety_info good_to_know]
    
    fields.each do |field|
      field_ru = "#{field}_ru".to_sym
      source_text = attributes[field] || product.read_attribute(field)
      
      if source_text.present? && (attributes[field_ru].blank? && (product.read_attribute(field_ru).blank? || product.read_attribute(field_ru) == product.read_attribute(field)))
        translated = TranslationService.translate(source_text.is_a?(Array) ? source_text.join("\n") : source_text)
        attributes[field_ru] = translated if translated.present? && !TranslationService.invalid_translation?(translated, source_text)
      end
    end
  end
end
