# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "nokogiri"

class IkeaLvProductVariantsService
  # Сначала PL (полный PIP / варианты с польской витрины), затем LT.
  PRODUCT_URL_TEMPLATES = [
    "https://www.ikea.com/pl/pl/p/-%{sku}/",
    "https://www.ikea.com/lt/ru/p/-%{sku}/"
  ].freeze

  SEARCH_URLS = [
    "https://www.ikea.com/lt/ru/search/?q=%{sku}"
  ].freeze

  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

  attr_reader :product, :force

  def initialize(product:, force: false)
    @product = product
    @force = force
  end

  def call
    target_url = find_product_url_by_sku(product.sku)
    target_url ||= product.url

    if target_url.blank?
      Rails.logger.error("IkeaLvProductVariantsService: Could not find URL for SKU #{product.sku}")
      return { changed: false, error: "URL not found" }
    end

    html = http_get(target_url)
    if html.blank?
      Rails.logger.error("IkeaLvProductVariantsService: Could not fetch HTML for SKU #{product.sku} at #{target_url}")
      return { changed: false, error: "HTML fetch failed" }
    end

    doc = Nokogiri::HTML(html)
    variants_data = extract_variants(doc)
    # variants_data = localize_variant_picker_images(variants_data) if variants_data.present?

    if variants_data.present?
      # Собираем все уникальные SKU из всех типов вариантов
      all_variant_skus = variants_data.flat_map { |v| v[:data].map { |d| d.dig(:item, :sku) } }.compact.uniq
      
      # Сохраняем расширенную структуру в payload
      # `variants` сериализуется Product через JSON coder. Передаём массив,
      # чтобы update_columns не сохранил JSON-массив как строковое значение.
      update_data = { variants: all_variant_skus, updated_at: Time.current }
      
      # Тип теперь может быть комбинированным, если их несколько
      if Product.column_names.include?("variant_type")
        update_data[:variant_type] = variants_data.map { |v| v[:type] }.join(",")
      end

      # Сохраняем массив вариантов
      if Product.column_names.include?("variants_payload")
        update_data[:variants_payload] = variants_data.to_json
      end

      if all_variant_skus.sort != product.normalized_variant_skus.sort || force
        product.update_columns(update_data)

        { changed: true, types: variants_data.map { |v| v[:type] }, count: all_variant_skus.size, data: variants_data }
      else
        { changed: false, types: variants_data.map { |v| v[:type] }, count: all_variant_skus.size, data: variants_data }
      end
    else
      { changed: false, count: 0 }
    end
  end

  private

  def localize_variant_picker_images(variants_data)
    Array(variants_data).each do |group|
      Array(group[:data] || group["data"]).each do |variant|
        item = variant[:item] || variant["item"]
        next unless item
  
        has_preview_images =
          item.key?(:preview_images) || item.key?("preview_images")
  
        source_images =
          Array(item[:images] || item["images"]) +
          Array(item[:preview_images] || item["preview_images"])
  
        remote_images =
          source_images
            .map(&:to_s)
            .map(&:strip)
            .reject(&:blank?)
            .select do |url|
              url.match?(/\Ahttps?:\/\//i) ||
                url.start_with?("//") ||
                url.match?(%r{\A/(pl|lt|globalassets)/}i)
            end
            .uniq
  
        next if remote_images.empty?
  
        local_refs = ImageDownloader.download_urls_to_refs(remote_images, limit: 1)
        next if local_refs.empty?
  
        item[:images] = local_refs
        item["images"] = local_refs
  
        # Не добавляем новое поле в API, если его раньше не было.
        # Но если preview_images уже есть в payload, тоже переводим его в локальный путь.
        if has_preview_images
          item[:preview_images] = local_refs
          item["preview_images"] = local_refs
        end
      end
    end
  
    variants_data
  end

  def extract_variants(doc)
    # Актуальная PIP-страница IKEA хранит варианты в JSON-гидратации. В нём
    # цвет и размер уже связаны с текущей комбинацией товара, поэтому для
    # жёлтого полотенца будут выбраны именно жёлтые размеры, а не размеры
    # первого попавшегося цвета из HTML.
    hydrated_variants = extract_variants_from_hydration(doc)
    return hydrated_variants if hydrated_variants.present?

    all_variants = []

    # 1. Проверяем цвета
    color_variants = extract_color_variants(doc)
    all_variants << { type: "color", data: color_variants } if color_variants.any?

    # 2. Проверяем размеры
    size_variants = extract_size_variants(doc)
    all_variants << { type: "size", data: size_variants } if size_variants.any?

    all_variants.presence
  end

  def extract_variants_from_hydration(doc)
    payloads = hydration_payloads_with_variants(doc)
    return nil if payloads.empty?

    groups = []

    style_picker = payloads.filter_map { |payload| deep_find_json_value(payload, "productStylePickerProps") }.first
    color_variants = extract_hydrated_color_variants(style_picker)
    groups << { type: "color", data: color_variants } if color_variants.any?

    specification = payloads.filter_map do |payload|
      deep_find_json_value(payload, "productSpecificationSectionProps")
    end.first
    size_variants = extract_hydrated_size_variants(specification)
    groups << { type: "size", data: size_variants } if size_variants.any?

    groups.presence
  end

  def hydration_payloads_with_variants(doc)
    doc.css('script[type="text/hydrate"]').filter_map do |script|
      raw = script.text.to_s.strip
      next if raw.blank?
      next unless raw.include?("productStylePickerProps") || raw.include?("productSpecificationSectionProps")

      parsed = JSON.parse(raw)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      next
    end
  end

  def deep_find_json_value(value, key)
    case value
    when Hash
      return value[key] if value.key?(key)
      return value[key.to_sym] if value.key?(key.to_sym)

      value.each_value do |nested|
        found = deep_find_json_value(nested, key)
        return found unless found.nil?
      end
    when Array
      value.each do |nested|
        found = deep_find_json_value(nested, key)
        return found unless found.nil?
      end
    end

    nil
  end

  def extract_hydrated_color_variants(style_picker)
    return [] unless style_picker.is_a?(Hash)

    picker = style_picker.deep_stringify_keys
    styles = Array(picker["variationStyles"])
    color_style = styles.find { |style| style.is_a?(Hash) && style["code"].to_s.casecmp("COLOUR").zero? }
    return [] unless color_style

    options = color_style["allOptions"] || color_style["options"]
    Array(options).filter_map do |option|
      next unless option.is_a?(Hash)

      option = option.deep_stringify_keys
      sku = hydrated_option_sku(option)
      next if sku.blank?

      label = option["title"].to_s.strip.presence || sku
      variant_product = find_variant_product_by_sku(sku)
      preview_images = [
        option.dig("valueImage", "url"),
        option.dig("image", "url")
      ].compact

      {
        color: label,
        item: variant_payload(
          variant_product,
          sku,
          cover_label: label,
          preview_images: preview_images
        )
      }
    end.uniq { |variant| variant.dig(:item, :sku).to_s.downcase }
  end

  def extract_hydrated_size_variants(specification)
    return [] unless specification.is_a?(Hash)

    specification = specification.deep_stringify_keys
    variations = Array(specification["variations"])
    size_variation = variations.find { |variation| variation.is_a?(Hash) && variation["code"].to_s.casecmp("SIZE").zero? }
    return [] unless size_variation

    Array(size_variation["options"]).filter_map do |option|
      next unless option.is_a?(Hash)

      option = option.deep_stringify_keys
      sku = hydrated_option_sku(option)
      next if sku.blank?

      label = option["title"].to_s.strip.presence || sku
      variant_product = find_variant_product_by_sku(sku)
      preview_images = [option.dig("image", "url")].compact

      {
        size: label,
        item: variant_payload(
          variant_product,
          sku,
          cover_label: label,
          preview_images: preview_images
        )
      }
    end.uniq { |variant| variant.dig(:item, :sku).to_s.downcase }
  end

  def hydrated_option_sku(option)
    option["linkId"].to_s.strip.presence || extract_sku_from_url(option["url"])
  end

  def extract_color_variants(doc)
    variants = []
    # Блок «Wybierz pokrycie» / обивка: .pipf-product-style-picker (PL PIP)
    picker = doc.at_css(".pipf-product-style-picker .pipf-product-style-picker__picker") ||
             doc.css(".pipf-product-style-picker__picker").first
    return [] unless picker

    items = picker.css(".pipf-product-style-picker__box")
    items.each do |item_node|
      link = item_node.at_css("a.pipf-product-style-picker__link")
      selected_div = item_node.at_css(".pipf-product-style-picker__item--selected")

      label = ""
      sku = ""
      if link
        label = normalize_cover_label(link["aria-label"])
        href = link["href"]
        sku = extract_sku_from_url(href)
      elsif selected_div
        label = normalize_cover_label(selected_div["aria-label"])
        sku = product.sku.to_s
      end

      next if sku.blank?

      variant_product = find_variant_product_by_sku(sku)
      display_color = color_display_label(variant_product, label.presence || sku)
      preview_images = extract_style_picker_images(item_node)

      variants << {
        color: display_color,
        item: variant_payload(
          variant_product,
          sku,
          cover_label: display_color,
          preview_images: preview_images
        )
      }
    end

    variants.uniq { |v| v.dig(:item, :sku).to_s.downcase }
  end

  def extract_style_picker_images(node)
    urls = []
  
    node.css("img, source").each do |img|
      %w[src data-src data-lazy-src data-original data-image].each do |attr|
        urls << img[attr] if img[attr].present?
      end
  
      %w[srcset data-srcset].each do |attr|
        srcset = img[attr].to_s
        next if srcset.blank?
  
        srcset.split(",").each do |part|
          candidate = part.to_s.strip.split(/\s+/).first
          urls << candidate if candidate.present?
        end
      end
    end
  
    urls
      .filter_map { |url| normalize_style_picker_image_url(url) }
      .uniq
  end
  
  def normalize_style_picker_image_url(raw)
    url = raw.to_s.strip
    return nil if url.blank?
  
    url = "https:#{url}" if url.start_with?("//")
    url = "https://www.ikea.com#{url}" if url.start_with?("/")
  
    return nil unless url.start_with?("http://", "https://")
    return nil unless url.include?("ikea.com")
    return nil if url.match?(/placeholder|icon|logo|sprite/i)
  
    # Убираем resize-query, чтобы не ловить дубли.
    clean = url.split("?").first
    return nil unless clean.match?(/\.(jpg|jpeg|png|webp)\z/i)
  
    clean
  end

  def extract_size_variants(doc)
    variants = []
    # Ищем блок размеров по селектору из ТЗ
    section = doc.css('.pipf-product-variation-section').first
    return [] unless section

    # В ТЗ указано, что ссылки на размеры находятся в .pipf-seo-content
    seo_content = section.at_css('.pipf-seo-content')
    return [] unless seo_content

    links = seo_content.css('a')
    links.each do |link|
      label = link.text.strip
      href = link['href']
      sku = extract_sku_from_url(href)
      
      next if sku.blank?
      
      variant_product = find_variant_product_by_sku(sku)
      variants << {
        size: label,
        item: variant_payload(variant_product, sku, cover_label: label)
      }
    end

    # Добавляем текущий продукт, если его нет в списке (он может быть выбранным и не иметь ссылки в seo-content)
    unless variants.any? { |v| v[:item][:sku] == product.sku }
      # Пытаемся найти текущий размер в кнопке
      current_size_label = section.at_css('.pipf-list-view-item__addon')&.text&.strip
      if current_size_label
        variants << {
          size: current_size_label,
          item: variant_payload(product, product.sku, cover_label: current_size_label)
        }
      end
    end

    variants
  end

  def color_display_label(variant_product, aria_label)
    variant_product&.small_desc_name.to_s.strip.presence ||
      aria_label.to_s.strip.presence ||
      variant_product&.sku.to_s
  end

  def variant_payload(variant_product, sku, cover_label: nil, preview_images: [])
    label = cover_label.to_s.strip
    preview_images = normalize_variant_images_for_sku(preview_images)
  
    base =
      if variant_product
        h = variant_product.variant_item_payload
        h[:small_desc_name] = h[:small_desc_name].presence || label.presence || h[:small_desc_name]
        h
      else
        slug =
          SlugifyService.call("#{label} #{sku}").presence ||
            "variant-#{sku.to_s.downcase.gsub(/[^a-z0-9]+/i, '-').gsub(/^-|-$/, '')}"
  
        {
          sku: sku,
          name_ru: product.name.to_s.presence,
          small_desc_name: label.presence || sku.to_s,
          slug: slug,
          price: nil,
          quantity: 0,
          images: []
        }
      end
  
    base[:sku] = sku.to_s
  
    # ВАЖНО:
    # Для цветового переключателя используем картинку из style-picker.
    # Она не должна попадать в product.images/local_images.
    product_images = normalize_variant_images_for_sku(base[:images])
  
    base[:preview_images] = preview_images if preview_images.any?
    base[:images] = preview_images.presence || product_images
  
    base
  end

  def normalize_variant_images_for_sku(raw_images)
    ProductLocalImages.normalize_api_image_array(raw_images)
      .reject { |u| u.to_s.include?("?f=") }
      .uniq
  end

  def normalize_cover_label(raw_label)
    s = raw_label.to_s.strip
    return s if s.blank?

    s = s.sub(/\A(?:wybierz\s+pokrycie|choose\s+cover)\s*:\s*/i, "")
    s = s.sub(/\A(?:current|selected)\s+/i, "")
    s.strip
  end

  def find_variant_product_by_sku(sku)
    s = sku.to_s.strip
    return if s.blank?

    Product.find_by(sku: s) ||
      Product.find_by(sku: s.sub(/\As/i, "")) ||
      Product.find_by(sku: "s#{s.delete_prefix('s').delete_prefix('S')}")
  end

  # PL PIP: ...-s29545213/ или ...-80541594/ (опционально #content)
  def extract_sku_from_url(url)
    return nil if url.blank?

    path =
      begin
        URI.parse(url.to_s.split("#").first.to_s.split("?").first).path
      rescue URI::InvalidURIError
        url.to_s.split(/[#?]/, 2).first.to_s
      end
    return nil if path.blank?

    m = path.match(/-([sS]?\d{8})\/?\z/)
    return m[1].downcase if m

    m2 = path.match(/-(\d{8})\/?\z/)
    m2 ? m2[1] : nil
  end

  def find_product_url_by_sku(sku)
    PRODUCT_URL_TEMPLATES.each do |template|
      product_url = format(template, sku: sku.to_s.gsub(".", ""))
      begin
        response = http_request_with_redirects(:get, product_url)
        if response.is_a?(Net::HTTPSuccess) && response.body.to_s.include?(sku.to_s.gsub(".", ""))
          final_url = response.instance_variable_get(:@final_url) || product_url
          return final_url if final_url.include?("/p/")
        end
      rescue; next; end
    end

    SEARCH_URLS.each do |search_url_template|
      search_url = format(search_url_template, sku: URI.encode_www_form_component(sku.to_s))
      begin
        search_html = http_get(search_url)
        next if search_html.blank?
        doc = Nokogiri::HTML(search_html)
        link = doc.css("a[href*='/p/']").find { |a| a["href"].include?(sku.to_s.gsub(".", "")) }
        return absolute_url(link["href"]) if link
      rescue; next; end
    end
    nil
  end

  def http_get(url)
    response = http_request_with_redirects(:get, url)
    response.body if response.is_a?(Net::HTTPSuccess)
  end

  def http_request(method, url, limit: 5)
    raise "Too many redirects" if limit <= 0
    # Используем ProxyRotator если он есть, иначе обычный Net::HTTP
    if defined?(ProxyRotator)
      ProxyRotator.with_proxy_retry do |proxy_options|
        uri = URI.parse(url)
        http = if proxy_options && proxy_options[:http_proxyaddr]
                 Net::HTTP.new(uri.host, uri.port, proxy_options[:http_proxyaddr], proxy_options[:http_proxyport], proxy_options[:http_proxyuser], proxy_options[:http_proxypass])
               else
                 Net::HTTP.new(uri.host, uri.port)
               end
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = 30
        request = Net::HTTP::Get.new(uri.request_uri, default_headers)
        http.request(request)
      end
    else
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 15
      http.read_timeout = 30
      request = Net::HTTP::Get.new(uri.request_uri, default_headers)
      http.request(request)
    end
  end

  def http_request_with_redirects(method, url, limit: 5)
    response = http_request(method, url) rescue nil
    if response.is_a?(Net::HTTPRedirection) && limit > 0
      location = response["location"]
      next_url = URI.join(url, location).to_s
      res = http_request_with_redirects(method, next_url, limit: limit - 1)
      res.instance_variable_set(:@final_url, next_url) if res.respond_to?(:instance_variable_set)
      res
    else
      response.instance_variable_set(:@final_url, url) if response && response.respond_to?(:instance_variable_set)
      response
    end
  end

  def default_headers
    {
      "User-Agent" => USER_AGENT,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,lv;q=0.8",
      "Cache-Control" => "no-cache"
    }
  end

  def absolute_url(url)
    return url if url.start_with?("http://", "https://")
    return "https:#{url}" if url.start_with?("//")
    "https://www.ikea.com#{url}"
  end
end
