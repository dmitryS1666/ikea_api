class ProductSerializer
  include FastJsonapi::ObjectSerializer

  attributes :small_desc_name,
             :slug,
             :price,
             :price_pln,
             :price_byn,
             :quantity,
             :is_bestseller,
             :is_new,
             :is_recommended,
             :is_popular,
             :category_id,
             :rating_avg,
             :rating_weighted,
             :rating_count,
             :rating_updated_at,
             :promo,
             :customs_duty,
             :included_products

  # Фронт по-прежнему читает ключ `name_ru`; значение — оригинальное полное имя с витрины (`name`).
  attribute :name_ru do |product|
    product.name.to_s.presence
  end

  # Вес для API (г): сумма весов всех элементов упаковки из `full_attributes` (details/packages).
  attribute :weight do |product|
    w = product.packaging_weight_kg
    next nil if w.blank?

    i = (w * 1000).round
    (i % 1000).zero? ? (i / 1000).to_s : format("%.2f", w).sub(/0+\z/, "").sub(/\.\z/, "")
  end

  attribute :promo do |product, params|
    promos = params[:active_promos] || PromoCode.active_now.to_a

    applicability = params[:promo_applicability] || {}
    applicable = if applicability.key?(product.sku)
                   applicability[product.sku]
                 else
                   cat_ids = [product.category_id] + product.category_products.map(&:category_id)
                   promos.select { |p| p.applies_to_sku?(product.sku, cat_ids) }
                 end

    best = applicable.max_by do |p|
      p.discount_type == 'percent' ? p.discount_value : (p.discount_value / 4.0)
    end

    if best
      {
        code: best.code,
        discount_value: best.discount_value.to_f,
        discount_type: best.discount_type
      }
    end
  end

  attribute :customs_duty do |product, params|
    safe_weight = safe_product_weight_kg(product)
  
    if product.price.to_f > 0 && safe_weight.present?
      rates = params[:rates] || {
        eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
        pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      }
  
      if rates[:eur] && rates[:pln]
        price_eur = (product.price.to_f * rates[:pln] / rates[:eur]).round(2)
        calculation = CustomsDutyService.calculate(price_eur, safe_weight, rates[:eur])
  
        {
          total_byn: calculation[:total_byn],
          duty_byn: calculation[:duty_byn],
          fee_byn: calculation[:fee_byn],
          details: calculation[:details]
        }
      end
    end
  end

  attribute :price_pln do |product|
    product.price.to_f
  end

  attribute :price_byn do |product, params|
    pln_price = product.price.to_f
  
    if pln_price > 0
      rates = params[:rates] || {}
      pln_rate = rates[:pln] || ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
  
      settings = params[:calculator_settings] || {}
      buffer = settings['exchange_rate_buffer'] || PriceCalculationService.exchange_rate_buffer
  
      price = PriceCalculationService.product_storefront_price_byn(
        pln_price,
        weight_kg: product.packaging_weight_kg.to_f,
        delivery_pln: product.delivery_cost.to_f,
        pln_rate: pln_rate,
        buffer: buffer
      )
  
      ActionController::Base.helpers.number_with_delimiter(price, delimiter: ' ')
    else
      "0"
    end
  end

  attribute :is_favorite do |product, params|
    Array(params[:favorite_skus]).include?(product.sku)
  end

  attribute :slug do |product|
    product.slug
  end

  attribute :variants do |product|
    product.normalized_variants_for_api
  end

  attribute :local_images do |product|
    ProductLocalImages.expand_paths(product.local_images)
  end

  attribute :related_products do |product|
    # CategoryRelatedProductList — канонический общий список для категории.
    # Он обогащается аксессуарами отдельных карточек при refresh, поэтому товары
    # одной категории должны получать одинаковый related_products.
    category_skus = CategoryRelatedProductList.skus_for_product(product)
    raw_product_related = product.related_products
    product_skus =
      if raw_product_related.is_a?(Array)
        raw_product_related
      elsif raw_product_related.is_a?(String) && raw_product_related.present?
        begin
          JSON.parse(raw_product_related)
        rescue JSON::ParserError
          []
        end
      else
        []
      end

    # CategoryRelatedProductList — канонический список для категории: он обогащается
    # аксессуарами отдельных карточек при refresh. Поэтому, если список категории уже
    # есть, отдаём его одинаковым для всех товаров категории. product.related_products
    # нужен как fallback для товаров без собранного category-level списка.
    items = category_skus.any? ? category_skus : product_skus

    skus = items.filter_map do |item|
      if item.is_a?(Hash)
        (item["sku"] || item[:sku] || item["item_no"] || item[:item_no]).presence
      else
        item.to_s.presence
      end
    end

    Product.filter_skus_with_available_stock(skus)
  end

  belongs_to :category, serializer: CategorySerializer, if: proc { |record| record.category.present? }
  has_many :categories, serializer: CategorySerializer

  attribute :delivery_days do |product, params|
    global_default = params[:calculator_settings]&.dig('default_delivery_days') || CalculatorSetting.get('default_delivery_days') || 30
    product.primary_category&.delivery_days.presence || global_default
  end

  attribute :display_blocks do |product, params|
    category = product.category
    settings = params[:calculator_settings] || {}

    global_delivery = (settings['show_delivery_block_global'] || CalculatorSetting.get('show_delivery_block_global')) != 0
    global_reviews  = (settings['show_reviews_block_global'] || CalculatorSetting.get('show_reviews_block_global')) != 0
    global_tips     = (settings['show_tips_block_global'] || CalculatorSetting.get('show_tips_block_global')) != 0

    cat_delivery = category&.show_delivery_block != false
    cat_reviews  = category&.show_reviews_block != false
    cat_tips     = category&.show_tips_block != false
    is_bulky     = category&.is_bulky == true

    {
      delivery: global_delivery && cat_delivery,
      reviews: global_reviews && cat_reviews,
      tips: global_tips && cat_tips,
      is_bulky: is_bulky,
      delivery_info: is_bulky ? nil : "Доставка- самовывоз со склада Минск"
    }
  end

  attribute :seo do |product, params|
    SeoHelper.meta_for(product, params[:city])
  end

  attribute :breadcrumbs, if: proc { |_product, params| params && params[:detail] } do |product|
    Seo::BreadcrumbsBuilder.for_product(product)
  end

  attribute :local_images_detailed, if: proc { |_product, params| params && params[:detail] } do |product, params|
    Seo::ImageTagsBuilder.for_product(product, params[:city])
  end

  attribute :structured_data, if: proc { |_product, params| params && params[:detail] } do |product, params|
    site_url = params[:site_url].presence || Seo::PublicSiteUrl.resolve
    Seo::StructuredData::ProductBuilder.build(product, site_url: site_url, city_code: params[:city])
  end

  attribute :tips, if: proc { |_product, params| params && params[:detail] } do |product|
    articles = ContentArticle.visible.tips_ideas.relevant_for_product(product).limit(5)
    ContentArticleTeaserSerializer.new(articles).serializable_hash[:data].map { |a| a[:attributes] }
  end

  # Карточка для витрины: собирается из jsonb full_attributes (модалки PIPF, detailed_info из JSONL) и колонок товара.
  # Временно ключ в API — full_attributes_ru (ожидание фронта); источник данных тот же — product.full_attributes.
  attribute :full_attributes_ru do |product|
    ProductSerializer.customer_full_attributes_payload(product)
  end

  def self.customer_full_attributes_payload(product)
    full = product.full_attributes.is_a?(Hash) ? product.full_attributes.deep_stringify_keys : {}
    detailed_info = full["detailed_info"].is_a?(Hash) ? full["detailed_info"].deep_stringify_keys : {}
    dimensions_map = full["dimensions_map"].is_a?(Hash) ? full["dimensions_map"].deep_stringify_keys : {}
    measurements_modal = full["measurements_modal"]
    product_details_modal = full["product_details_modal"]

    dimensions_map = dimensions_map.merge(dimensions_map_from_measurements_modal(measurements_modal))
    if dimensions_map.except("packaging").blank?
      dimensions_map = dimensions_map.merge(dimensions_map_from_product_column(product.dimensions))
    end

    description = ProductSerializer.build_description_block(full, detailed_info)
    enrich_description_block_from_product!(description, product, product_details_modal)

    size = ProductSerializer.build_size_block(dimensions_map, detailed_info["Информация об упаковке"])
    enrich_size_block_from_measurements_modal!(size, measurements_modal, product)
    size["packages"] = ProductSerializer.build_packages_for_customer_payload(size, measurements_modal)
    normalize_size_block_ru!(size)

    materials = ProductSerializer.build_materials_block(detailed_info["Материал и уход"])
    enrich_materials_block_from_product!(materials, product, product_details_modal)

    instructions = ProductSerializer.build_instructions_block(detailed_info["Сборка и документы"])
    enrich_instructions_block_from_product!(instructions, product, product_details_modal)
    instructions["files"] = dedupe_instruction_files(instructions["files"])

    payload = {
      "description" => description,
      "size" => size,
      "materials" => materials,
      "instructions" => instructions
    }

    override = full[Product::FULL_ATTRIBUTES_API_OVERRIDE_KEY]
    if override.is_a?(Hash)
      payload.deep_merge(override.deep_stringify_keys)
    else
      payload
    end
  end

  # Только size/packages для веса упаковки и ВГХ (admin XLSX, без лишних колонок Product).
  def self.customer_size_payload_for_product(product)
    full = product.full_attributes.is_a?(Hash) ? product.full_attributes.deep_stringify_keys : {}
    detailed_info = full["detailed_info"].is_a?(Hash) ? full["detailed_info"].deep_stringify_keys : {}
    dimensions_map = full["dimensions_map"].is_a?(Hash) ? full["dimensions_map"].deep_stringify_keys : {}
    measurements_modal = full["measurements_modal"]

    dimensions_map = dimensions_map.merge(dimensions_map_from_measurements_modal(measurements_modal))
    if dimensions_map.except("packaging").blank?
      dimensions_map = dimensions_map.merge(dimensions_map_from_product_column(product.dimensions))
    end

    size = build_size_block(dimensions_map, detailed_info["Информация об упаковке"])
    enrich_size_block_from_measurements_modal!(size, measurements_modal, product)
    size["packages"] = build_packages_for_customer_payload(size, measurements_modal)
    normalize_size_block_ru!(size)

    { "size" => size }
  end

  def self.build_description_block(full, detailed_info)
    short_description = full["short_description"].presence

    description_items = normalize_description_items(
      detailed_info["Описание"] || detailed_info["Полное описание"]
    )
    if description_items.empty?
      gi = detailed_info["Полезная информация"].to_s.strip.presence
      description_items = normalize_description_items(gi) if gi.present?
    end

    {
      "short_description" => short_description,
      "description" => description_items
    }
  end

  def self.enrich_description_block_from_product!(block, product, product_details_modal)
    block["short_description"] ||= product.short_description.presence
    return block if block["description"].present?

    paras = Array(product_details_modal&.dig("intro_paragraphs")).map(&:to_s).map(&:strip).reject(&:blank?)
    if paras.any?
      block["description"] = paras
    elsif product.content.present?
      block["description"] = normalize_description_items(product.content)
    end
    block
  end

  def self.dimensions_map_from_measurements_modal(measurements_modal)
    return {} unless measurements_modal.is_a?(Hash)
  
    out = {}
  
    Array(measurements_modal["product_measurements"]).each do |row|
      next unless row.is_a?(Hash)
  
      name = translate_measurement_label_for_api(row["name"] || row[:name])
      measure = normalize_api_measurement_value(row["measure"] || row[:measure])
  
      next if name.blank? || measure.blank?
  
      out[name] ||= measure
    end
  
    out
  end

  # "142 × 100 × 87 cm" → три базовых ключа для блока размеров
  def self.dimensions_map_from_product_column(dimensions_str)
    s = dimensions_str.to_s.strip
    return {} if s.blank?
  
    parts = s.split(/\s*[×x]\s*/i).map(&:strip)
    return {} if parts.size < 3
  
    w, d, h = parts[0], parts[1], parts[2]
  
    {
      "Ширина" => normalize_api_measurement_value(w),
      "Глубина" => normalize_api_measurement_value(d),
      "Высота" => normalize_api_measurement_value(h)
    }
  end

  def self.safe_product_weight_kg(product)
    Products::WeightExtractor.packaging_weight_kg_for_product(product)
  end

  MEASUREMENT_KEYS = %w[length width height weight diameter].freeze

  PACKAGE_MEASUREMENT_LABELS_RU = {
    "width" => "Ширина",
    "height" => "Высота",
    "length" => "Длина",
    "depth" => "Глубина",
    "weight" => "Вес",
    "diameter" => "Диаметр"
  }.freeze

  DIMENSION_LABELS_RU = {
    "ширина" => "Ширина",
    "szerokość" => "Ширина",
    "szerokosc" => "Ширина",
    "width" => "Ширина",
    "глубина" => "Глубина",
    "głębokość" => "Глубина",
    "glebokosc" => "Глубина",
    "depth" => "Глубина",
    "высота" => "Высота",
    "wysokość" => "Высота",
    "wysokosc" => "Высота",
    "height" => "Высота",
    "длина" => "Длина",
    "długość" => "Длина",
    "dlugosc" => "Длина",
    "length" => "Длина",
    "макс нагрузка" => "Макс нагрузка",
    "maksymalne obciążenie" => "Макс нагрузка",
    "maksymalne obciazenie" => "Макс нагрузка",
    "объем" => "Объем",
    "pojemność" => "Объем",
    "pojemnosc" => "Объем",
    "volume" => "Объем",
    "вес" => "Вес",
    "waga" => "Вес",
    "weight" => "Вес",
    "диаметр" => "Диаметр",
    "diameter" => "Диаметр",
    "упаковка(-и)" => "Упаковка(-и)",
    "paczka(i)" => "Упаковка(-и)",
    "packages" => "Упаковка(-и)",
    "grubość" => "Толщина",
    "grubosc" => "Толщина",
    "thickness" => "Толщина",
    "minimalna szerokość" => "Мин ширина",
    "min width" => "Мин ширина",

    "maksymalna szerokość" => "Макс ширина",
    "maksymalna szerokosc" => "Макс ширина",
    "max width" => "Макс ширина",

    "szerokość po lewej" => "Ширина слева",
    "szerokosc po lewej" => "Ширина слева",
    "szerokość po prawej" => "Ширина справа",
    "szerokosc po prawej" => "Ширина справа",
    "wysokość łóżka" => "Высота кровати",
    "wysokosc lozka" => "Высота кровати",
    "wysokość z poduchami oparcia" => "Высота с подушками спинки",
    "wysokosc z poduchami oparcia" => "Высота с подушками спинки",
    "wysokość oparcia" => "Высота спинки",
    "wysokosc oparcia" => "Высота спинки",
    "głębokość całkowita po rozłożeniu" => "Общая глубина в разложенном виде",
    "glebokosc calkowita po rozlozeniu" => "Общая глубина в разложенном виде",
    "głębokość siedziska, szezlong" => "Глубина сиденья, козетка",
    "glebokosc siedziska, szezlong" => "Глубина сиденья, козетка",
    "grubość materaca" => "Толщина матраса",
    "grubosc materaca" => "Толщина матраса",
    "maksymalna grubość materaca" => "Максимальная толщина матраса",
    "maksymalna grubosc materaca" => "Максимальная толщина матраса",
    "gęstość nici" => "Плотность нитей",
    "gestosc nici" => "Плотность нитей",
    "wysokość podłokietnika" => "Высота подлокотника",
    "wysokosc podlokietnika" => "Высота подлокотника",

    "waga wypełnienia" => "Вес наполнителя",
    "waga wypelnienia" => "Вес наполнителя",
    "filling weight" => "Вес наполнителя",

    "całkowita waga" => "Общий вес",
    "calkowita waga" => "Общий вес",
    "total weight" => "Общий вес",

    "głębokość do zabudowy" => "Глубина для встраивания",
    "glebokosc do zabudowy" => "Глубина для встраивания",
    "built-in depth" => "Глубина для встраивания",
    "depth for built-in" => "Глубина для встраивания",

    "obciążenie półki" => "Нагрузка на полку",
    "obciazenie polki" => "Нагрузка на полку",

    "maks. obciążenie/półka szklana" => "Макс. нагрузка на стеклянную полку",
    "maks. obciazenie/polka szklana" => "Макс. нагрузка на стеклянную полку"
  }.freeze

  ARTICLE_IN_LABEL_RE = /\b(\d{3}\.\d{3}\.\d{2})\b|\b(\d{8})\b/.freeze

  # Для фронта: «как в LT» (packages с measurements[]) + совместимость с упрощённым packaging.details.
  def self.build_packages_for_customer_payload(size_block, measurements_modal)
    from_modal = extract_packages_from_measurements_modal(measurements_modal)
    return from_modal if from_modal.any?
  
    packaging = size_block["packaging"] || size_block[:packaging]
    packages_from_packaging_block(packaging)
  end

  def self.extract_packages_from_measurements_modal(mm)
    return [] unless mm.is_a?(Hash)
  
    raw = mm["packages"] || mm[:packages]
    packages = Array(raw)
  
    packages.flat_map do |pkg|
      split_package_measurements_if_needed(pkg)
    end.compact
  end

  def self.split_package_measurements_if_needed(pkg)
    return [] unless pkg.is_a?(Hash)
  
    measurements =
      Array(pkg["measurements"] || pkg[:measurements])
        .map { |row| normalize_package_measurement_row(row) }
        .compact
  
    return [] if measurements.empty?
  
    groups = []
    current = []
  
    measurements.each do |row|
      name = row["name"].to_s
  
      # Если пошла новая "Ширина", а в текущем блоке уже был вес/кол-во,
      # значит началась следующая физическая упаковка.
      if name == "Ширина" && current.any? && current.any? { |r| %w[Вес Упаковка(-и)].include?(r["name"]) }
        groups << current
        current = []
      end
  
      current << row
  
      # Paczka(i) обычно закрывает одну упаковку.
      if name == "Упаковка(-и)"
        groups << current
        current = []
      end
    end
  
    groups << current if current.any?
  
    groups.each_with_index.map do |group, idx|
      next if group.empty?
  
      copy = pkg.deep_dup
      copy["measurements"] = group
  
      # Если исходный package_label отсутствует, но упаковок несколько —
      # проставляем Paczka N.
      if copy["package_label"].blank? && groups.size > 1
        copy["package_label"] = "Paczka #{idx + 1}"
      end
  
      copy
    end.compact
  end
  
  def self.normalize_package_measurement_row(row)
    return nil unless row.is_a?(Hash)
  
    name = row["name"] || row[:name]
    measure = row["measure"] || row[:measure]
  
    name = translate_measurement_label_for_api(name)
    measure = normalize_api_measurement_value(measure)
  
    return nil if name.blank? || measure.blank?
  
    {
      "name" => name,
      "measure" => measure
    }
  end

  def self.translate_measurement_label_for_api(label)
    s = label.to_s.gsub(/\u00A0/, " ").gsub(/\s+/, " ").strip.gsub(":", "")
  
    case s.downcase
    when "szerokość", "szerokosc", "width", "ширина"
      "Ширина"
    when "głębokość", "glebokosc", "depth", "глубина"
      "Глубина"
    when "wysokość", "wysokosc", "height", "высота"
      "Высота"
    when "długość", "dlugosc", "length", "длина"
      "Длина"
    when "długość łóżka", "dlugosc lozka"
      "Длина кровати"
    when "szerokość łóżka", "szerokosc lozka"
      "Ширина кровати"
    when "wysokość siedziska", "wysokosc siedziska"
      "Высота сиденья"
    when "wysokość łóżka", "wysokosc lozka"
      "Высота кровати"
    when "wysokość z poduchami oparcia", "wysokosc z poduchami oparcia"
      "Высота с подушками спинки"
    when "wysokość oparcia", "wysokosc oparcia"
      "Высота спинки"
    when "wysokość podłokietnika", "wysokosc podlokietnika"
      "Высота подлокотника"
    when "głębokość siedziska", "glebokosc siedziska"
      "Глубина сиденья"
    when "głębokość całkowita po rozłożeniu", "glebokosc calkowita po rozlozeniu"
      "Общая глубина в разложенном виде"
    when "szerokość siedziska", "szerokosc siedziska"
      "Ширина сиденья"
    when "głębokość siedziska, szezlong", "glebokosc siedziska, szezlong"
      "Глубина сиденья, козетка"
    when "głębokość szezlonga", "glebokosc szezlonga"
      "Глубина козетки"
    when "waga", "weight", "вес"
      "Вес"
    when /\Aobciążenie półki\b/i, /\Aobciazenie polki\b/i
      "Нагрузка на полку"
    when /\Amaks\. obciążenie\/półka szklana\b/i, /\Amaks\. obciazenie\/polka szklana\b/i
      "Макс. нагрузка на стеклянную полку"
    when "paczka(i)", "paczki", "package(s)", "packages", "упаковка(-и)"
      "Упаковка(-и)"
    when "grubość", "grubosc", "thickness", "толщина"
      "Толщина"
    when "grubość materaca", "grubosc materaca"
      "Толщина матраса"
    when "maksymalna grubość materaca", "maksymalna grubosc materaca"
      "Максимальная толщина матраса"
    when "gęstość nici", "gestosc nici"
      "Плотность нитей"
    when "głębokość do zabudowy", "glebokosc do zabudowy", "built-in depth", "depth for built-in"
      "Глубина для встраивания"
    else
      s
    end
  end
  
  def self.normalize_api_measurement_value(value)
    s = value.to_s.gsub(/\u00A0/, " ").gsub(/\s+/, " ").strip
    return nil if s.blank?
  
    s = s.gsub(/\bcm\b/i, "см")
    s = s.gsub(/\bkg\b/i, "кг")
    s = s.gsub(/\bg\b/i, "гр")
    s = s.gsub(%r{/\s*inch\s*[²2]\b?}i, "/дюйм²")
    s = s.gsub(/\binch\s*[²2]\b?/i, "дюйм²")
    s = s.gsub(/\b(\d+)\.0(?=\s|$)/, '\1')
  
    s
  end

  def self.normalize_package_entry_from_modal(pkg)
    return nil unless pkg.is_a?(Hash)

    pkg = pkg.stringify_keys
    measurements = normalize_package_measurements_rows(pkg["measurements"])
    return nil if measurements.empty? && pkg["name"].blank?

    out = {}
    out["name"] = pkg["name"].presence
    out["type_name"] = (pkg["type_name"] || pkg["typeName"]).presence
    art = pkg["article_number"] || pkg["articleNumber"]
    if art.is_a?(Hash)
      h = art.stringify_keys
      lab = "Номер товара"
      val = h["value"].presence
      out["article_number"] = { "label" => lab, "value" => val } if val.present?
    elsif art.present?
      out["article_number"] = { "label" => "Номер товара", "value" => art.to_s.strip }
    end
    out["measurements"] = measurements if measurements.any?
    out.compact.presence
  end

  def self.normalize_package_measurements_rows(raw)
    Array(raw).filter_map do |m|
      case m
      when Hash
        m = m.stringify_keys
        n = normalize_measurement_label_ru(m["name"])
        v = (m["measure"] || m["value"]).to_s.strip
        next if n.blank? || v.blank?

        { "name" => n, "measure" => v }
      end
    end
  end

  def self.packages_from_packaging_block(packaging)
    return [] unless packaging.is_a?(Hash)

    Array(packaging["details"]).filter_map do |row|
      next unless row.is_a?(Hash)

      row = row.stringify_keys
      name, type_name, article_raw = parse_packaging_three_part_label(row["label"])
      name ||= packaging["desc"].presence

      measurements = []
      PACKAGE_MEASUREMENT_LABELS_RU.each do |en, ru|
        v = row[en]
        measurements << { "name" => ru, "measure" => v.to_s.strip } if v.present?
      end
      if row["count"].present?
        measurements << { "name" => "Упаковка(-и)", "measure" => row["count"].to_s.strip }
      end

      article_display = article_raw.presence || format_article_dots(extract_article_from_desc(packaging["desc"]))
      article_number =
        if article_display.present?
          { "label" => "Номер товара", "value" => article_display }
        end

      {
        "name" => name,
        "type_name" => type_name,
        "measurements" => measurements,
        "article_number" => article_number
      }.compact
    end
  end

  def self.parse_packaging_three_part_label(label)
    return [nil, nil, nil] if label.to_s.blank?

    parts = label.to_s.split(/\s*·\s*/).map(&:strip).reject(&:blank?)
    article = parts.find { |p| p.match?(ARTICLE_IN_LABEL_RE) }
    rest = parts.reject { |p| p == article }
    name = rest[0].presence
    type_name = rest[1].presence if rest.size > 1
    raw_art = article&.match(ARTICLE_IN_LABEL_RE)&.captures&.compact&.first
    [name, type_name, raw_art]
  end

  def self.extract_article_from_desc(desc)
    return nil if desc.to_s.blank?

    desc.to_s.match(ARTICLE_IN_LABEL_RE)&.captures&.compact&.first
  end

  def self.format_article_dots(raw)
    return nil if raw.blank?

    s = raw.to_s.strip
    return s if s.include?(".")

    d = s.gsub(/\D/, "")
    return s if d.length != 8

    "#{d[0, 3]}.#{d[3, 3]}.#{d[6, 2]}"
  end

  def self.packaging_missing_physical_measurements?(packaging)
    return true unless packaging.is_a?(Hash)

    details = packaging["details"]
    return true unless details.is_a?(Array)
    return true if details.empty?

    details.none? do |row|
      row.is_a?(Hash) && MEASUREMENT_KEYS.any? { |k| row[k].present? }
    end
  end

  def self.enrich_size_block_from_measurements_modal!(size_block, measurements_modal, product)
    return unless size_block.is_a?(Hash)
  
    if measurements_modal.is_a?(Hash)
      modal_packaging = build_packaging_from_measurements_modal(measurements_modal)
  
      # ВАЖНО:
      # Если measurements_modal содержит упаковки, они имеют приоритет.
      # Не даём старому fallback product.package_dimensions + product.weight
      # схлопнуть несколько физических упаковок в одну строку.
      if Array(modal_packaging["details"]).any?
        size_block["packaging"] = modal_packaging
        return
      end
    end
  
    # Старый fallback оставляем только если modal packages реально нет.
    if product.package_dimensions.present? && product.weight.present?
      fallback_packaging = build_packaging_from_product_columns(product)

      size_block["packaging"] ||= {}
      size_block["packaging"]["desc"] ||= fallback_packaging["desc"]
      if Array(size_block["packaging"]["details"]).blank?
        size_block["packaging"]["details"] = fallback_packaging["details"]
      end
    end
  end

  def self.build_packaging_from_product_columns(product)
    pd = product.package_dimensions.to_s
    parts = pd.split(/\s*[×x]\s*/i).map(&:strip)
    detail = {}
    detail["width"] = parts[0] if parts[0].present?
    detail["height"] = parts[1] if parts[1].present?
    detail["length"] = parts[2] if parts[2].present?
    detail["weight"] = "#{product.weight} кг" if product.weight.present?
    details = detail.values.any? ? [detail.compact] : []
    { "desc" => nil, "details" => details }
  end

  def self.build_packaging_from_measurements_modal(measurements_modal)
    return { "desc" => nil, "details" => [] } unless measurements_modal.is_a?(Hash)
  
    note = measurements_modal["package_count_note"].presence
    note ||= "Упаковок: #{measurements_modal["number_of_packages"]}" if measurements_modal["number_of_packages"].present?
    note = normalize_package_count_note(note)
  
    details =
      extract_packages_from_measurements_modal(measurements_modal).filter_map do |pkg|
        package_row_to_api_detail(pkg)
      end
  
    {
      "desc" => note,
      "details" => details
    }
  end

  def self.normalize_package_count_note(note)
    s = note.to_s.gsub(/\u00A0/, " ").gsub(/\s+/, " ").strip
    return nil if s.blank?

    if (m = s.match(/\ATen produkt składa się z (\d+) paczek\.?\z/i))
      return "Этот товар состоит из #{m[1]} упаковок."
    end

    s
  end

  def self.package_row_to_api_detail(pkg)
    return nil unless pkg.is_a?(Hash)
  
    measurements = Array(pkg["measurements"] || pkg[:measurements])
  
    values = measurements.each_with_object({}) do |row, memo|
      next unless row.is_a?(Hash)
  
      name = translate_measurement_label_for_api(row["name"] || row[:name])
      measure = normalize_api_measurement_value(row["measure"] || row[:measure])
  
      memo[name] = measure if name.present? && measure.present?
    end
  
    width = values["Ширина"]
    height = values["Высота"]
    length = values["Длина"]
    weight = values["Вес"]
  
    count = values["Упаковка(-и)"].to_i
    count = 1 if count <= 0
  
    return nil if width.blank? && height.blank? && length.blank? && weight.blank?
  
    article =
      pkg["article_number"] ||
      pkg[:article_number] ||
      {}
  
    article_value =
      if article.is_a?(Hash)
        article["value"] || article[:value]
      end
  
    label_parts = [
      pkg["name"] || pkg[:name],
      pkg["type_name"] || pkg[:type_name],
      article_value
    ].compact.map(&:to_s).reject(&:blank?)
  
    {
      "width" => width,
      "height" => height,
      "length" => length,
      "weight" => weight,
      "count" => count,
      "label" => label_parts.join(" · "),
      "package_label" => pkg["package_label"] || pkg[:package_label]
    }.compact
  end

  def self.normalize_size_block_ru!(size_block)
    return size_block unless size_block.is_a?(Hash)

    normalized = {}
    size_block.each do |key, value|
      key_s = key.to_s
      next if key_s == "packaging" || key_s == "packages"

      ru_key = normalize_measurement_label_ru(key_s)
      next if ru_key.blank?
      next if normalized.key?(ru_key) && normalized[ru_key].present?

      normalized[ru_key] = normalize_api_measurement_value(value)
    end

    packaging = size_block["packaging"]
    packages = size_block["packages"]
    size_block.clear
    normalized.each { |k, v| size_block[k] = v }
    size_block["packaging"] = packaging if packaging.present?

    if packages.is_a?(Array)
      packages.each do |pkg|
        next unless pkg.is_a?(Hash)

        if pkg["article_number"].is_a?(Hash)
          pkg["article_number"]["label"] = "Номер товара"
        end

        Array(pkg["measurements"]).each do |row|
          next unless row.is_a?(Hash)

          row["name"] = normalize_measurement_label_ru(row["name"])
        end
      end
    end

    size_block["packages"] = packages if packages.present?
    size_block
  end

  def self.normalize_measurement_label_ru(label)
    base = label.to_s.gsub(":", "").strip
    return nil if base.blank?

    key = base.downcase
    return DIMENSION_LABELS_RU[key] if DIMENSION_LABELS_RU[key]

    stripped = key.sub(/\s+[\d.,]+\s*(кг|kg|г)\s*\z/i, "").strip
    return DIMENSION_LABELS_RU[stripped] if DIMENSION_LABELS_RU[stripped]

    base
  end

  def self.enrich_materials_block_from_product!(block, product, product_details_modal)
    mats = block["materials"]
    empty = mats.blank? || (mats.is_a?(Hash) && mats.empty?)
    return block unless empty

    # LT modal в full_attributes (русские пары); колонка materials часто остаётся от PL.
    modal_hash = materials_hash_from_product_details_modal(product_details_modal)
    if modal_hash.present?
      block["materials"] = modal_hash.stringify_keys
      return block
    end

    column_materials = product.materials.to_s.strip.presence
    if column_materials.present? && !polish_materials_text?(column_materials)
      block["materials"] = { "Материалы и уход" => column_materials }
      return block
    end

    text = materials_text_from_product_details_modal(product_details_modal)
    if text.present?
      block["materials"] = { "Материалы и уход" => text }
      return block
    end

    block["materials"] = { "Материалы и уход" => column_materials } if column_materials.present?
    block
  end

  def self.polish_materials_text?(text)
    TranslationService.needs_polish_to_russian_translation?(text)
  rescue StandardError
    false
  end

  MODAL_MATERIAL_DEFAULT_KEY = "Состав"
  MODAL_CARE_DEFAULT_KEY = "Уход"

  # Пары term/definition + care_blocks из секции material-and-care (как на витрине LT).
  def self.materials_hash_from_product_details_modal(pdm)
    return {} unless pdm.is_a?(Hash)

    sec = Array(pdm["accordion_sections"]).find { |s| s.is_a?(Hash) && s["id"].to_s.include?("material-and-care") }
    return {} unless sec

    out = {}
    Array(sec["material_blocks"]).each do |blk|
      next unless blk.is_a?(Hash)

      Array(blk["pairs"]).each do |pair|
        next unless pair.is_a?(Hash)

        t = pair["term"].to_s.strip.delete_suffix(":").strip
        d = pair["definition"].to_s.strip
        next if t.blank? && d.blank?

        if t.present?
          out[t] = d
        elsif d.present?
          k = MODAL_MATERIAL_DEFAULT_KEY
          out[k] = out[k].present? ? "#{out[k]}; #{d}" : d
        end
      end
    end

    Array(sec["care_blocks"]).each do |blk|
      next unless blk.is_a?(Hash)

      care_lines = Array(blk["lines"]).map(&:to_s).map(&:strip).reject(&:blank?)
      next if care_lines.blank?

      header = blk["header"].to_s.strip.presence
      care_key = header.presence || MODAL_CARE_DEFAULT_KEY
      chunk = care_lines.join("\n")
      out[care_key] = out[care_key].present? ? "#{out[care_key]}\n#{chunk}" : chunk
    end

    out
  end

  def self.materials_text_from_product_details_modal(pdm)
    return nil unless pdm.is_a?(Hash)

    sec = Array(pdm["accordion_sections"]).find { |s| s.is_a?(Hash) && s["id"].to_s.include?("material-and-care") }
    return nil unless sec

    lines = []
    Array(sec["material_blocks"]).each do |blk|
      next unless blk.is_a?(Hash)

      lines << blk["subheader"] if blk["subheader"].present?
      Array(blk["pairs"]).each do |pair|
        next unless pair.is_a?(Hash)

        t = pair["term"].to_s.strip
        d = pair["definition"].to_s.strip
        next if t.blank? && d.blank?

        lines << (t.present? ? "#{t} #{d}".strip : d)
      end
    end

    Array(sec["care_blocks"]).each do |blk|
      next unless blk.is_a?(Hash)

      Array(blk["lines"]).each do |ln|
        s = ln.to_s.strip
        lines << s if s.present?
      end
    end

    lines.reject(&:blank?).join("\n").presence
  end

  def self.enrich_instructions_block_from_product!(block, product, product_details_modal)
    files =
      if block["files"].present?
        Array(block["files"])
      else
        f = extract_instruction_files(product.assembly_documents)
        if f.blank?
          raw = instruction_files_from_product_details_modal(product_details_modal)
          f = raw.filter_map { |item| normalize_instruction_item(item) }
        end
        f
      end
    block["files"] = dedupe_instruction_files(files) if files.present?
    block
  end

  def self.instruction_files_from_product_details_modal(pdm)
    return [] unless pdm.is_a?(Hash)

    out = []
    Array(pdm["accordion_sections"]).each do |sec|
      next unless sec.is_a?(Hash)

      Array(sec["document_groups"]).each do |grp|
        next unless grp.is_a?(Hash)

        Array(grp["links"]).each do |ln|
          next unless ln.is_a?(Hash)

          url = ln["url"].to_s.strip
          next if url.blank?

          title = ln["title"].to_s.strip.presence || File.basename(url)
          out << { "url" => url, "title" => title }
        end
      end
    end
    out.uniq { |x| instruction_link_dedupe_key(x["url"]) }
  end
  
  def self.build_size_block(dimensions_map, packaging_info)
    size_data = dimensions_map.is_a?(Hash) ? dimensions_map.deep_dup.stringify_keys : {}

    existing_packaging = size_data["packaging"].is_a?(Hash) ? size_data["packaging"].deep_stringify_keys : nil
    built_packaging = build_packaging_block(packaging_info)

    # `dimensions_map` may already contain normalized packaging/details from imports or specs.
    # Do not wipe it with an empty block when detailed_info has no packaging section.
    size_data["packaging"] = if packaging_block_present?(built_packaging)
                                built_packaging
                              elsif packaging_block_present?(existing_packaging)
                                existing_packaging
                              else
                                built_packaging
                              end

    size_data
  end

  def self.packaging_block_present?(value)
    return false unless value.is_a?(Hash)

    value["desc"].present? || Array(value["details"]).any?
  end
  
  def self.build_packaging_block(packaging_info)
    return { "desc" => nil, "details" => [] } unless packaging_info.is_a?(Hash)
  
    count = packaging_info["Упаковка(-и)"] || packaging_info[:'Упаковка(-и)']
  
    details_item = {
      "count" => integer_or_original(count),
      "length" => packaging_info["Длина"],
      "width" => packaging_info["Ширина"],
      "height" => packaging_info["Высота"],
      "weight" => packaging_info["Вес"]
    }

    desc_parts = [
      packaging_info["Название"],
      packaging_info["Артикульный номер"]
    ].compact

    # Только count из detailed_info без габаритов давал непустой details и блокировал merge из measurements_modal.
    physical = MEASUREMENT_KEYS.any? { |k| details_item[k].present? }
    details = physical ? [details_item] : []
  
    {
      "desc" => desc_parts.join(", ").presence,
      "details" => details
    }
  end
  
  def self.build_materials_block(materials_info)
    {
      "desc" => nil,
      "materials" => materials_info.is_a?(Hash) ? materials_info.stringify_keys : {}
    }
  end
  
  def self.build_instructions_block(raw_instructions)
    {
      "files" => dedupe_instruction_files(extract_instruction_files(raw_instructions))
    }
  end

  # Один PDF часто дублируется (разные записи в JSONL/модалке, http/https, слэш в конце).
  def self.instruction_link_dedupe_key(link)
    s = link.to_s.strip.downcase
    s = s.sub(/\Ahttp:\/\//, "https://")
    s.sub(/\/+\z/, "")
  end

  def self.dedupe_instruction_files(files)
    seen = {}
    Array(files).each_with_object([]) do |item, acc|
      next unless item.is_a?(Hash)

      raw = item["link"] || item[:link]
      key = instruction_link_dedupe_key(raw)
      next if key.blank?
      next if seen[key]

      seen[key] = true
      acc << item
    end
  end

  def self.extract_instruction_files(raw_instructions)
    case raw_instructions
    when Array
      raw_instructions.filter_map { |item| normalize_instruction_item(item) }
    when Hash
      [normalize_instruction_item(raw_instructions)].compact
    when String
      extract_links_from_text(raw_instructions)
    else
      []
    end
  end
  
  def self.normalize_instruction_item(item)
    return unless item.is_a?(Hash)
  
    link = item["link"] || item[:link] || item["url"] || item[:url] || item["local_url"] || item[:local_url]
    title = item["title"] || item[:title] || item["name"] || item[:name]
  
    return if link.blank?
  
    {
      "link" => link,
      "title" => title.presence || File.basename(link.to_s)
    }
  end
  
  def self.extract_links_from_text(text)
    return [] if text.blank?
  
    text.scan(/https?:\/\/\S+|\/documents\/\S+/).uniq.map do |link|
      {
        "link" => link,
        "title" => File.basename(link.to_s)
      }
    end
  end
  
  def self.normalize_description_items(value)
    case value
    when Array
      value.filter_map { |item| item.to_s.strip.presence }
    when String
      value.split(/\n+/).filter_map { |item| item.strip.presence }
    else
      []
    end
  end
  
  def self.integer_or_original(value)
    return nil if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    value
  end

  def self.normalize_documents(documents)
    Array(documents).filter_map do |doc|
      if doc.is_a?(Hash)
        url = doc["url"] || doc[:url]
        local_url = doc["local_url"] || doc[:local_url]
        title = doc["title"] || doc[:title]
        next if url.blank? && local_url.blank?

        final_url = local_url.presence || url
        { title: title, url: final_url }.compact
      else
        url = doc.to_s
        next if url.blank?

        { url: url }
      end
    end
  end

  def self.normalize_variants(raw)
    entries = case raw
              when Array then raw
              when Hash then [raw]
              when String
                begin
                  JSON.parse(raw)
                rescue JSON::ParserError
                  []
                end
              else
                []
              end

    entries.map do |entry|
      if entry.is_a?(Hash)
        {
          sku: extract_variant_sku(entry),
          name_ru: extract_variant_name(entry),
          small_desc_name: extract_variant_small_desc_name(entry),
          price: extract_variant_price(entry),
          images: extract_variant_images(entry),
          quantity: extract_variant_quantity(entry)
        }
      else
        {
          name: entry.to_s.presence,
          small_desc_name: nil,
          price: nil,
          images: [],
          quantity: nil
        }
      end
    end
  end

  def self.extract_variant_small_desc_name(entry)
    entry["small_desc_name"] || entry[:small_desc_name]
  end

  def self.extract_variant_name(entry)
    entry["name"] || entry[:name] ||
      entry["name_ru"] || entry[:name_ru] ||
      entry["typeName"] || entry[:typeName] ||
      entry["validDesignText"] || entry[:validDesignText]
  end

  def self.extract_variant_sku(entry)
    entry["id"] || entry[:id] ||
      entry["itemNoGlobal"] || entry[:itemNoGlobal] ||
      entry["itemNo"] || entry[:itemNo]
  end

  def self.extract_variant_price(entry)
    price = entry.dig("salesPrice", "numeral") ||
            entry.dig(:salesPrice, :numeral) ||
            entry.dig("price", "numeral") ||
            entry.dig(:price, :numeral) ||
            entry["price"] ||
            entry[:price]

    if price.is_a?(String)
      price = price.gsub(/[^\d,.]/, "").gsub(",", ".").to_f
    end

    price
  end

  def self.extract_variant_images(entry)
    images = entry["local_images"] || entry[:local_images]
    normalize_variant_images(images)
  end

  def self.extract_variant_quantity(entry)
    quantity = entry["quantity"] || entry[:quantity]
    if quantity.is_a?(Hash)
      quantity = quantity["quantity"] || quantity[:quantity]
    end
    quantity
  end

  def self.normalize_variant_images(value)
    return [] if value.blank?

    if value.is_a?(String)
      begin
        value = JSON.parse(value)
      rescue JSON::ParserError
        return value.present? ? [value] : []
      end
    end

    Array(value).filter_map do |item|
      if item.is_a?(Hash)
        item["url"] || item[:url] ||
          item["imageUrl"] || item[:imageUrl]
      else
        s = item.to_s.strip.presence
        next unless s

        ProductLocalImages.expand_path(s) || s
      end
    end
  end

  def self.public_sku(sku)
    sku.to_s.sub(/\As(?=\d+\z)/i, "")
  end

  attribute :sku do |product|
    public_sku(product.sku)
  end

  attribute :included_products do |product|
    if product.respond_to?(:reject_self_from_article_list)
      product.reject_self_from_article_list(product.included_products)
    else
      Products::ArticleNumber.normalize_list(product.included_products)
    end
  end
end
