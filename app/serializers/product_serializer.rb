class ProductSerializer
  include FastJsonapi::ObjectSerializer

  attributes :sku,
             :name_ru,
             :small_desc_name,
             :slug,
             :price,
             :price_pln,
             :price_byn,
             :quantity,
             :weight,
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
    if product.price.to_f > 0 && product.weight.to_f > 0
      rates = params[:rates] || {
        eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
        pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
      }

      if rates[:eur] && rates[:pln]
        price_eur = (product.price.to_f * rates[:pln] / rates[:eur]).round(2)
        calculation = CustomsDutyService.calculate(price_eur, product.weight.to_f, rates[:eur])

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
  
      price = PriceCalculationService.product_price_byn(pln_price, pln_rate: pln_rate, buffer: buffer)
  
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
    images = product.local_images
    if images.is_a?(String)
      begin
        JSON.parse(images)
      rescue JSON::ParserError
        [images]
      end
    else
      Array(images)
    end
  end

  attribute :related_products do |product|
    raw = product.related_products
    items = if raw.is_a?(Array)
              raw
            elsif raw.is_a?(String) && raw.present?
              begin
                JSON.parse(raw)
              rescue JSON::ParserError
                []
              end
            else
              []
            end

    items.filter_map do |item|
      if item.is_a?(Hash)
        (item["sku"] || item[:sku] || item["item_no"] || item[:item_no]).presence
      else
        item.to_s.presence
      end
    end
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

    materials = ProductSerializer.build_materials_block(detailed_info["Материал и уход"])
    enrich_materials_block_from_product!(materials, product, product_details_modal)

    instructions = ProductSerializer.build_instructions_block(detailed_info["Сборка и документы"])
    enrich_instructions_block_from_product!(instructions, product, product_details_modal)

    {
      "description" => description,
      "size" => size,
      "materials" => materials,
      "instructions" => instructions
    }
  end

  def self.build_description_block(full, detailed_info)
    short_description = full["short_description"].presence

    description_items = normalize_description_items(
      detailed_info["Описание"] || detailed_info["Полное описание"]
    )

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

      name = row["name"].to_s.gsub(":", "").strip
      measure = row["measure"].to_s.strip
      next if name.blank? || measure.blank?

      out[name] = measure
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
      "Ширина" => w,
      "Глубина" => d,
      "Высота" => h
    }
  end

  def self.enrich_size_block_from_measurements_modal!(size_block, measurements_modal, product)
    packaging = size_block["packaging"]
    if packaging.is_a?(Hash) && packaging["details"].is_a?(Array) && packaging["details"].empty?
      merged = build_packaging_from_measurements_modal(measurements_modal)
      if merged["details"].any? || merged["desc"].present?
        size_block["packaging"] = merged
      elsif product.package_dimensions.present? && product.weight.present?
        size_block["packaging"] = build_packaging_from_product_columns(product)
      end
    end
    size_block
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
    if note.blank? && measurements_modal["number_of_packages"].present?
      note = "Упаковок: #{measurements_modal["number_of_packages"]}"
    end

    details = Array(measurements_modal["packages"]).filter_map { |pkg| package_row_to_api_detail(pkg) }
    { "desc" => note, "details" => details }
  end

  def self.package_row_to_api_detail(pkg)
    return nil unless pkg.is_a?(Hash)

    if pkg["measurements"].is_a?(Array) && pkg["measurements"].first.is_a?(Array)
      w = h = l = wt = diam = nil
      Array(pkg["measurements"]).each do |grp|
        Array(grp).each do |it|
          next unless it.is_a?(Hash)

          case it["type"].to_s
          when "width"
            w = it["text"].presence
            w ||= "#{it['value']} см" if it["value"].present?
          when "height"
            h = it["text"].presence
            h ||= "#{it['value']} см" if it["value"].present?
          when "length", "depth"
            l = it["text"].presence
            l ||= "#{it['value']} см" if it["value"].present?
          when "diameter"
            diam = it["text"].presence
            diam ||= "#{it['value']} см" if it["value"].present?
          when "weight"
            wt = it["text"].presence
            wt ||= "#{it['value']} кг" if it["value"].present?
          end
        end
      end
      ct = pkg.dig("quantity", "value")
      label = [pkg["name"], pkg["typeName"], pkg.dig("articleNumber", "value")].compact.join(" · ").presence
      d = {
        "count" => integer_or_original(ct),
        "length" => l,
        "width" => w,
        "height" => h,
        "weight" => wt,
        "diameter" => diam
      }.compact
      d["label"] = label if label.present?
      return nil if d.except("label").empty?

      d
    end

    hmap = {}
    Array(pkg["measurements"]).each do |m|
      next unless m.is_a?(Hash)

      n = m["name"].to_s.downcase
      v = m["measure"].to_s.strip
      next if v.blank?

      if n.match?(/ширина|szerokość|szerokosc|width/)
        hmap["width"] = v
      elsif n.match?(/высота|wysokość|wysokosc|height/)
        hmap["height"] = v
      elsif n.match?(/длина|długość|dlugosc|length/)
        hmap["length"] = v
      elsif n.match?(/диаметр|diameter/)
        hmap["diameter"] = v
      elsif n.match?(/вес|weight|waga/)
        hmap["weight"] = v
      elsif n.match?(/упаковка/)
        hmap["count"] = integer_or_original(v)
      end
    end
    label = [pkg["name"], pkg["type_name"], pkg.dig("article_number", "value")].compact.join(" · ").presence
    d = hmap.compact
    d["label"] = label if label.present?
    return nil if d.except("label").empty?

    d
  end

  def self.enrich_materials_block_from_product!(block, product, product_details_modal)
    mats = block["materials"]
    empty = mats.blank? || (mats.is_a?(Hash) && mats.empty?)
    return block unless empty

    if product.materials.present?
      block["materials"] = { "Материалы и уход" => product.materials }
      return block
    end

    text = materials_text_from_product_details_modal(product_details_modal)
    block["materials"] = { "Материалы и уход" => text } if text.present?
    block
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
        lines << "#{t} #{d}".strip if t.present? || d.present?
      end
    end
    lines.reject(&:blank?).join("\n").presence
  end

  def self.enrich_instructions_block_from_product!(block, product, product_details_modal)
    return block if block["files"].present?

    files = extract_instruction_files(product.assembly_documents)
    if files.blank?
      raw = instruction_files_from_product_details_modal(product_details_modal)
      files = raw.filter_map { |item| normalize_instruction_item(item) }
    end
    block["files"] = files if files.present?
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
    out.uniq { |x| x["url"] }
  end
  
  def self.build_size_block(dimensions_map, packaging_info)
    size_data = dimensions_map.is_a?(Hash) ? dimensions_map.deep_dup.stringify_keys : {}
  
    size_data["packaging"] = build_packaging_block(packaging_info)
  
    size_data
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
  
    details = details_item.values.compact.any? ? [details_item] : []
  
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
      "files" => extract_instruction_files(raw_instructions)
    }
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
    entry["name_ru"] || entry[:name_ru] ||
      entry["name"] || entry[:name] ||
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
        item.to_s.presence
      end
    end
  end

  attribute :included_products do |product|
    Array(product.included_products).filter_map do |item|
      item.to_s.gsub(/[\[\]\"]/, '').strip.presence
    end.uniq
  end
end
