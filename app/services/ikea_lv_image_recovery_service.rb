# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "nokogiri"
require "shellwords"
require "digest/sha1"
require "fileutils"
require "tempfile"

class IkeaLvImageRecoveryService
    # Список доменов и шаблонов URL для поиска продукта (в порядке приоритета)
    PRODUCT_URL_TEMPLATES = [
      "https://www.ikea.com/lt/ru/p/-%{sku}/",
      "https://www.ikea.com/pl/pl/p/-%{sku}/",
      "https://www.ikea.com/us/en/p/-%{sku}/",
      "https://www.ikea.com/lv/ru/p/-%{sku}/"
    ].freeze
  
    SEARCH_URLS = [
      "https://www.ikea.com/lt/ru/search/?q=%{sku}",
      "https://www.ikea.pl/pl/search/?q=%{sku}",
      "https://www.ikea.com/us/en/search/?q=%{sku}"
    ].freeze

  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

  attr_reader :product, :images_limit, :force

  def initialize(product:, images_limit: nil, force: false)
    @product = product
    @images_limit = images_limit&.to_i
    @force = force
  end

  def call
    # 1. Если не force, проверяем текущее состояние
    unless force
      remote_image_urls = parse_remote_images(product.images)
      existing_local_paths = parse_local_images(product.local_images)

      if remote_image_urls.any? && remote_image_urls.size == existing_local_paths.size
        all_valid = existing_local_paths.all? do |path|
          full_path = full_public_path(path)
          File.exist?(full_path) && image_readable?(full_path)
        end
        
        if all_valid
          Rails.logger.info("IkeaLvImageRecoveryService: SKU #{product.sku} already has all images (#{existing_local_paths.size}). Skipping.")
          return { changed: false, local_images_count: existing_local_paths.size }
        end
      end
    end

    # 2. Очищаем перед началом
    clear_local_images!

    # 3. Если force: true, мы ВСЕГДА пытаемся найти URL товара и распарсить его заново, 
    # так как ссылки в product.images могут быть устаревшими или неправильными (как в случае с SKU 10549230)
    target_url = find_product_url_by_sku(product.sku)
    target_url ||= product.url # Fallback на URL из базы, если шаблоны не сработали
    
    if target_url.present?
      Rails.logger.info("IkeaLvImageRecoveryService: Found source URL for SKU #{product.sku}: #{target_url}. Parsing images...")
      remote_image_urls = fetch_images_from_url(target_url)
      
      if remote_image_urls.any?
        downloaded_paths = download_available_images(remote_image_urls)
        
        if downloaded_paths.any?
          return save_and_result(downloaded_paths, target_url, remote_urls: remote_image_urls)
        end
      end
    end

    # 4. Резервный вариант: если не удалось найти URL или распарсить его, 
    # пробуем использовать то, что уже было в product.images (если не в режиме force)
    unless force
      remote_image_urls = parse_remote_images(product.images)
      if remote_image_urls.any?
        Rails.logger.info("IkeaLvImageRecoveryService: Falling back to product.images for SKU #{product.sku}")
        downloaded_paths = download_available_images(remote_image_urls)
        return save_and_result(downloaded_paths, "existing_product_images") if downloaded_paths.any?
      end
    end

    # 5. Если совсем ничего не помогло
    { changed: false, local_images_count: 0, product_url: target_url }
  end

  private

  def fetch_images_from_url(url)
    html = http_get(url)
    return [] if html.blank?

    extract_product_image_urls(html)
  end

  def clear_local_images!
    paths = parse_local_images(product.local_images)
    paths.each do |path|
      full_path = full_public_path(path)
      FileUtils.rm_f(full_path) if File.exist?(full_path)
    end
    ActiveRecord::Base.connection_pool.with_connection do
      product.update_columns(local_images: [].to_json, images_total: 0)
    end
  end

  def parse_remote_images(raw)
    parsed = if raw.is_a?(String)
               raw.strip.present? ? JSON.parse(raw) : []
             elsif raw.is_a?(Array)
               raw
             else
               []
             end
    Array(parsed).compact.map(&:to_s).map(&:strip).reject(&:blank?)
  rescue JSON::ParserError
    []
  end

  def parse_local_images(raw)
    parsed = if raw.is_a?(String)
               raw.strip.present? ? JSON.parse(raw) : []
             elsif raw.is_a?(Array)
               raw
             else
               []
             end
    Array(parsed).compact.map(&:to_s).map(&:strip).reject(&:blank?)
  rescue JSON::ParserError
    []
  end

  def download_available_images(urls)
    urls.filter_map do |remote_url|
      download_and_store_image(remote_url)
    rescue StandardError => e
      Rails.logger.error("IkeaLvImageRecoveryService: download failed sku=#{product.sku} url=#{remote_url} error=#{e.class} #{e.message}")
      nil
    end
  end

  def save_and_result(downloaded, product_url, remote_urls: nil)
    final_paths = downloaded.uniq
    
    update_data = {
      local_images: final_paths.to_json,
      images_total: final_paths.size,
      updated_at: Time.current
    }
    
    # Если мы нашли новые удаленные ссылки, обновляем и их тоже
    update_data[:images] = remote_urls.to_json if remote_urls.present?

    ActiveRecord::Base.connection_pool.with_connection do
      product.update_columns(update_data)
    end

    {
      changed: true,
      repaired_images: 0,
      downloaded_images: final_paths.size,
      product_url: product_url,
      local_images_count: final_paths.size
    }
  end

  def find_product_url_by_sku(sku)
    # 1. Шаблоны
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

    # 2. Поиск
    SEARCH_URLS.each do |search_url_template|
      search_url = format(search_url_template, sku: URI.encode_www_form_component(sku.to_s))
      begin
        search_html = http_get(search_url)
        next if search_html.blank?
        doc = Nokogiri::HTML(search_html)
        
        # Пытаемся найти ссылку на товар
        link = doc.css("a[href*='/p/']").find { |a| a["href"].include?(sku.to_s.gsub(".", "")) }
        return absolute_url(link["href"]) if link
      rescue; next; end
    end
    
    nil
  end

  def extract_product_image_urls(html)
    doc = Nokogiri::HTML(html)
    urls = []

    # 1. Пытаемся достать из JSON-LD
    doc.css('script[type="application/ld+json"]').each do |script|
      begin
        data = JSON.parse(script.text)
        main_entity = data.is_a?(Array) ? data.find { |d| d["@type"] == "Product" } : data
        if main_entity && main_entity["@type"] == "Product" && main_entity["image"]
          Array(main_entity["image"]).each do |img|
            if img.is_a?(Hash)
              urls << (img["contentUrl"] || img["url"])
            else
              urls << img
            end
          end
        end
      rescue JSON::ParserError; end
    end

    # 2. Пытаемся достать из hydration props (Блок "Все медиафайлы")
    product_pip = doc.css('.js-product-pip, [data-hydration-props]').first
    if product_pip
      begin
        props_text = product_pip['data-hydration-props'] || product_pip.text
        if props_text.present?
          props = JSON.parse(props_text)
          
          # Ищем именно в media или gallery, что обычно соответствует блоку "Все медиафайлы"
          media = props.dig('gallery', 'media') || 
                  props.dig('gallery', 'items') || 
                  props.dig('galleryData', 'media') || 
                  props.dig('galleryData', 'items') ||
                  props.dig('mediaSection', 'images') ||
                  props.dig('productMedia', 'images')
          
          if media.is_a?(Array)
            media.each do |m|
              # В блоке медиафайлов обычно объекты с url
              url = m.dig('content', 'url') || m['url'] || m['contentUrl']
              
              # Проверяем, что это именно картинка, а не видео
              type = m['type'] || m['mediaType']
              next if type && !['image', 'photo'].include?(type.to_s.downcase)
              
              urls << url if url && ikea_image_url?(url)
            end
          end
        end
      rescue JSON::ParserError; end
    end

    # 3. Если из props ничего не нашли, пробуем селекторы, специфичные для галереи
    if urls.empty?
      doc.css('.pip-product-gallery img, .pipf-product-gallery img, .pip-media-grid img').each do |img|
        src = img['src'] || img['data-src'] || img['data-src-full']
        urls << src if src && ikea_image_url?(src)
      end
    end

    urls = urls.map { |u| cleanup_url(u) }.select { |u| ikea_image_url?(u) }.uniq
    images_limit.present? ? urls.first(images_limit) : urls
  end

  def download_and_store_image(remote_url)
    attempts = 0
    begin
      attempts += 1
      body, content_type = http_get_binary(remote_url)
      return nil if body.blank?

      ext = detect_extension(remote_url, content_type, body)
      digest = Digest::SHA1.hexdigest(remote_url)
      relative_dir = File.join("images", "products", digest[0..1], digest[2..3], digest[4..5])
      absolute_dir = Rails.root.join("public", relative_dir)

      FileUtils.mkdir_p(absolute_dir)
      filename = "#{digest}.webp"
      absolute_path = absolute_dir.join(filename)

      begin
        if ext == ".webp"
          File.binwrite(absolute_path, body)
        else
          Tempfile.open(["ikea_lv", ext], binmode: true) do |source_tmp|
            source_tmp.write(body)
            source_tmp.flush
            convert_to_webp!(source_tmp.path, absolute_path.to_s)
          end
        end

        if image_readable?(absolute_path)
          return "/#{File.join(relative_dir, filename)}"
        else
          FileUtils.rm_f(absolute_path) # Удаляем битый файл (Требование 1)
          nil
        end
      rescue => e
        FileUtils.rm_f(absolute_path) if File.exist?(absolute_path)
        raise e
      end
    rescue => e
      retry if attempts < 2
      Rails.logger.error("IkeaLvImageRecoveryService: Failed to download #{remote_url} after 2 attempts")
      nil
    end
  end

  def convert_to_webp!(source_path, target_path)
    system("convert #{Shellwords.escape(source_path)} -quality 82 webp:#{Shellwords.escape(target_path)}")
  end

  def image_readable?(full_path)
    system("identify #{Shellwords.escape(full_path.to_s)} > /dev/null 2>&1")
  end

  def detect_extension(url, content_type, body)
    return ".webp" if content_type.to_s.include?("image/webp")
    return ".jpg"  if content_type.to_s.include?("image/jpeg")
    return ".png"  if content_type.to_s.include?("image/png")
    ".jpg"
  end

  def ikea_image_url?(url)
    return false if url.blank?
    normalized = cleanup_url(url)
    normalized.include?("ikea.com") && normalized.match?(/\.(jpg|jpeg|png|webp)(\?|$)/i)
  end

  def cleanup_url(url)
    return "" if url.blank?
    absolute_url(url).gsub("\\u002F", "/").gsub("\\/", "/")
  end

  def absolute_url(url)
    return url if url.start_with?("http://", "https://")
    return "https:#{url}" if url.start_with?("//")
    "https://www.ikea.com#{url}"
  end

  def normalize_local_path(path)
    path.start_with?("/") ? path : "/#{path}"
  end

  def full_public_path(path)
    Rails.root.join("public", path.sub(%r{\A/}, ""))
  end

  def http_request(method, url, limit: 5)
    raise "Too many redirects" if limit <= 0
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
      response = http.request(request)
      response
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

  def http_get(url)
    response = http_request_with_redirects(:get, url)
    response.body if response.is_a?(Net::HTTPSuccess)
  end

  def http_get_binary(url)
    response = http_request_with_redirects(:get, url)
    return [nil, nil] unless response.is_a?(Net::HTTPSuccess)
    [response.body, response["content-type"].to_s]
  end

  def default_headers
    {
      "User-Agent" => USER_AGENT,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9,lv;q=0.8",
      "Cache-Control" => "no-cache"
    }
  end
end
