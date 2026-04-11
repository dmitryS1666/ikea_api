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

    if variants_data.present?
      # Собираем все уникальные SKU из всех типов вариантов
      all_variant_skus = variants_data.flat_map { |v| v[:data].map { |d| d.dig(:item, :sku) } }.compact.uniq
      
      # Сохраняем расширенную структуру в payload
      update_data = { variants: all_variant_skus.to_json, updated_at: Time.current }
      
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

  def extract_variants(doc)
    all_variants = []

    # 1. Проверяем цвета
    color_variants = extract_color_variants(doc)
    all_variants << { type: "color", data: color_variants } if color_variants.any?

    # 2. Проверяем размеры
    size_variants = extract_size_variants(doc)
    all_variants << { type: "size", data: size_variants } if size_variants.any?

    all_variants.presence
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
      preview_src = style_picker_preview_src(item_node)

      if link
        label = link["aria-label"].to_s.strip
        href = link["href"]
        sku = extract_sku_from_url(href)
      elsif selected_div
        label = selected_div["aria-label"].to_s.strip
        sku = product.sku.to_s
      end

      next if sku.blank?

      variant_product = find_variant_product_by_sku(sku)
      display_color = color_display_label(variant_product, label.presence || sku)
      variants << {
        color: display_color,
        item: variant_payload(variant_product, sku, preview_image: preview_src, cover_label: display_color)
      }
    end

    variants.uniq { |v| v.dig(:item, :sku).to_s.downcase }
  end

  def style_picker_preview_src(item_node)
    img = item_node.at_css("img.pipf-image") || item_node.at_css("img")
    src = img&.[]("src").to_s.strip
    return if src.blank?

    src.start_with?("http") ? src : absolute_url(src)
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

  def variant_payload(variant_product, sku, preview_image: nil, cover_label: nil)
    label = cover_label.to_s.strip
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
          name_ru: product.name_ru,
          small_desc_name: label.presence || sku.to_s,
          slug: slug,
          price: nil,
          quantity: 0,
          images: []
        }
      end
    base[:sku] = sku.to_s
    enrich_item_images!(base, preview_image)
    base
  end

  def enrich_item_images!(base, preview_image)
    return if preview_image.blank?

    imgs = Array(base[:images]).compact
    base[:images] = imgs.empty? ? [preview_image] : ([preview_image] + imgs).uniq
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
