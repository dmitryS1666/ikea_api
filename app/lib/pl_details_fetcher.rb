# Парсер детальной страницы продукта IKEA Poland
require 'nokogiri'
require 'net/http'
require 'uri'
require 'ferrum'
require 'fileutils'
require 'securerandom'
require 'json'
require 'tmpdir'
require 'strscan'

class PlDetailsFetcher
  # Пути по умолчанию (Linux/macOS); на проде без браузера Ferrum падает с BinaryNotFoundError.
  BROWSER_PATH_CANDIDATES = %w[
    /usr/bin/google-chrome-stable
    /usr/bin/google-chrome
    /usr/bin/chromium
    /usr/bin/chromium-browser
    /snap/bin/chromium
    /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  ].freeze

  def self.resolved_chromium_path_for_headless
    %w[CHROME_PATH BROWSER_PATH].each do |key|
      p = ENV[key].to_s.strip
      return p if p.present? && File.executable?(p)
    end

    BROWSER_PATH_CANDIDATES.find { |path| File.executable?(path) }
  end

  def self.headless_browser_executable_available?
    resolved_chromium_path_for_headless.present?
  end

  # Схлопываем дубли одного и того же документа (http/https, слэш в конце, регистр).
  def self.canonical_document_url_for_dedupe(url)
    s = url.to_s.strip.downcase
    s = s.sub(/\Ahttp:\/\//, "https://")
    s.sub(/\/+\z/, "")
  end

  def self.fetch(url, use_headless: true, scope_sku: nil)
    new(scope_sku: scope_sku).fetch(url, use_headless: use_headless)
  end

  # Парсинг готового HTML (например, полученного через scrape.do)
  def self.parse_html(html, url = nil, use_headless: true, scope_sku: nil)
    new(scope_sku: scope_sku).parse_html(html, url, use_headless: use_headless)
  end

  def initialize(scope_sku: nil)
    @scope_sku = scope_sku
  end
  
  def fetch(url, use_headless: true)
    full_url = url.start_with?('http') ? url : "https://www.ikea.com#{url}"

    # 1) Fast path: direct fetch via rotating proxies
    html = fetch_with_proxy(full_url)
    parsed = parse_html(html, full_url, use_headless: use_headless)

    # 2) Fallback: remote JS rendering via scrape.do (still HTTP + HTML parsing)
    # Useful when IKEA returns minimal non-hydrated HTML.
    if should_fallback_to_js_render?(parsed, html)
      rendered_html = fetch_via_scrape_do(full_url)
      if rendered_html.present? && rendered_html.length > html.to_s.length
        rendered = parse_html(rendered_html, full_url, use_headless: use_headless)
        # Prefer the version that has more extended fields.
        return choose_best_parse(parsed, rendered)
      end
    end

    parsed
  end

  # Минимальный разбор страницы товара PL: цена в PLN (злотые), наличие, canonical URL.
  # Без модалок, headless, изображений и прочего — для фоновых задач «только полка».
  def self.shelf_snapshot(url)
    new.shelf_snapshot(url)
  end

  def shelf_snapshot(url)
    full_url = url.to_s.start_with?("http") ? url : "https://www.ikea.com#{url}"
    html = fetch_with_proxy(full_url)
    return {} unless html.present?

    doc = Nokogiri::HTML(html)
    href = doc.at_css('link[rel="canonical"]')&.[]("href")
    canonical_url =
      if href.present?
        href.start_with?("http") ? href : URI.join("https://www.ikea.com", href).to_s
      else
        full_url
      end

    product_data = parse_hydration_product_data(doc)

    schema = extract_json_ld(doc)
    price = shelf_snapshot_pln_price_from_json_ld(schema)
    if price.blank? && product_data.is_a?(Hash)
      price = shelf_snapshot_pln_price_from_hydration(product_data)
    end

    availability = extract_availability(doc, product_data)

    {
      price: price,
      price_currency: "PLN",
      availability: availability,
      canonical_url: canonical_url
    }
  end

  def parse_html(html, url = nil, use_headless: true)
    return {} unless html.present?
    
    full_url = url || 'https://www.ikea.com/pl/pl/'
    doc = Nokogiri::HTML(html)

    result = {}
    pipcom_heading = extract_pipcom_product_heading_parts(doc)

    # JSON-LD Product schema
    product_schema = extract_json_ld(doc)
    if product_schema
      result[:name] = product_schema['name']
      result[:sku] = product_schema['mpn']
      result[:images] = Array(product_schema['image'])
      if product_schema['offers']
        result[:price] = product_schema['offers']['price']
      end
      
      # Извлекаем размеры из JSON-LD
      if product_schema['width'] || product_schema['height'] || product_schema['depth']
        width = product_schema['width']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
        height = product_schema['height']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
        depth = product_schema['depth']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
        
        if width && depth
          result[:dimensions] = "#{width} × #{depth} × #{height || 'N/A'} cm"
          Rails.logger.debug "PlDetailsFetcher: Dimensions from JSON-LD: #{result[:dimensions]}"
        end
      end
    end

    # PIPCOM: в h1 имя и подзаголовок разведены по span; JSON-LD часто даёт склеенную строку.
    if pipcom_heading[:name].present?
      result[:name] = pipcom_heading[:name]
    end

    # Collection
    collection = doc.css('.pip-header-section__title--big').text.strip
    result[:collection] = collection if collection.present?
    
    # Product data (hydration props)
    product_data = nil
    
    # 1. Пробуем найти в атрибуте data-hydration-props (старый формат)
    product_data_attr = doc.css('.js-product-pip, [data-hydration-props]').first&.attribute('data-hydration-props')&.value
    
    # 2. Пробуем найти в скриптах с типом text/hydration или text/hydrate (новый формат)
    if product_data_attr.blank?
      doc.css('script[type="text/hydration"], script[type="text/hydrate"]').each do |script|
        script_text = script.text
        if script_text.include?('packaging') && script_text.include?('product')
          product_data_attr = script_text
          Rails.logger.debug "PlDetailsFetcher: Found product hydration script (length: #{script_text.length})"
          break
        end
      end
    end
    
    # 3. Пробуем найти в window.__FIKA_HYDRATION_DATA__ (еще один формат)
    if product_data_attr.blank?
      doc.css('script').each do |script|
        if script.text.include?('__FIKA_HYDRATION_DATA__')
          match = script.text.match(/window\.__FIKA_HYDRATION_DATA__\s*=\s*(\{.*?\});/m)
          product_data_attr = match[1] if match
          break
        end
      end
    end

    if product_data_attr
      begin
        # Очищаем от возможных комментариев или лишних символов
        json_str = product_data_attr.strip
        product_data = JSON.parse(json_str)
        result[:product_data] = product_data
        Rails.logger.debug "PlDetailsFetcher: Successfully parsed product_data (keys: #{product_data.keys.join(', ')})"
      rescue JSON::ParserError => e
        Rails.logger.warn("PlDetailsFetcher: Failed to parse product data: #{e.message}")
        # Если не распарсилось как JSON, возможно там JS-код с объектом
        # (случай window.__FIKA_HYDRATION_DATA__)
      end
    end
    
    # Weight, dimensions, etc. (обязательно вызываем, даже если product_data пустой)
    packaging_info = extract_packaging_info(doc, product_data)
    result.merge!(packaging_info)
    Rails.logger.info "PlDetailsFetcher: Packaging info extracted - weight: #{packaging_info[:weight]}, dimensions: #{packaging_info[:dimensions]}"
    
    # Product description and extended attributes (обязательно вызываем)
    # NOTE: On the new IKEA PIPF pages, some sections are displayed inside
    # UI "sheets" that become visible only after clicking a button in the UI.
    # However, for many products the section content is already present in the
    # initial HTML response (as normal headings + content blocks). We therefore
    # extract key sections by their headings (e.g. "Informacje o produkcie",
    # "Wymiary", etc.) even when the modal DOM is not present.
    description_data = extract_product_description(doc, product_data)
    result.merge!(description_data)
    Rails.logger.info "PlDetailsFetcher: Description data extracted - description: #{description_data[:description].present?}, materials: #{description_data[:materials].present?}"
    
    # Наборы (set_items), «товары в наборе» только из модалки PIPF, сопутствующие товары
    si = extract_set_items(product_data, doc)
    result[:set_items] = si if si.any?
    rp = extract_related_products(product_data, doc)
    result[:related_products] = rp if rp.any?
    ip = extract_included_products(product_data, doc)
    result[:included_products] = ip if ip.any?
    included_sheet_needs_headless = ip.empty? && included_products_sheet_clickable?(doc)
    sv = extract_variants(product_data, doc)
    result[:variants] = sv if sv.any?
    vpt = infer_variant_picker_types_from_doc(doc)
    result[:variant_picker_types] = vpt if vpt.present?
    sdn = pipcom_heading[:small_desc_name].presence || extract_small_desc_name(product_data, doc)
    result[:small_desc_name] = sdn if sdn.present?
    
    # Images - строго из области галереи товара (pipf-product-gallery-modal),
    # с мягким fallback на контейнеры pipf-product-gallery.
    all_images = extract_images(doc, product_data, result[:images] || [])
    result[:images] = all_images
    
    # Videos
    result[:videos] = extract_videos(doc, product_data)
    
    # Manuals
    result[:manuals] = extract_manuals(doc, product_data)
    
    # Извлекаем наличие из HTML (если доступно)
    result[:availability] = extract_availability(doc, product_data)
    
    # Извлекаем данные из модального окна с описанием продукта
    modal_data = extract_modal_details(doc, product_data)
    
    # Если модальное окно не найдено или данные неполные, используем headless браузер.
    # Отдельно: «Elementy w zestawie» открывается только по клику — без headless состав набора в DOM не появляется.
    modal_incomplete =
      modal_data[:materials].blank? || modal_data[:care_instructions].blank? || modal_data[:safety_info].blank?
    if use_headless && (modal_incomplete || included_sheet_needs_headless) && self.class.headless_browser_executable_available?
      Rails.logger.info "PlDetailsFetcher: headless browser (modal_incomplete=#{modal_incomplete}, included_sheet=#{included_sheet_needs_headless})"
      headless_modal_data = fetch_modal_with_headless_browser(full_url)
      modal_data.merge!(headless_modal_data) if headless_modal_data.present?
    elsif use_headless && (modal_incomplete || included_sheet_needs_headless)
      Rails.logger.warn "PlDetailsFetcher: headless нужен, но нет Chrome/Chromium (CHROME_PATH / BROWSER_PATH)"
    end

    prev_included = Array(result[:included_products])
    result.merge!(modal_data)
    if modal_data[:included_products].present?
      result[:included_products] = (prev_included + Array(modal_data[:included_products])).uniq
    end

    meas = extract_pipf_measurements_modal_combined(doc, product_data)
    meas[:fields].each do |k, v|
      next if v.blank?

      result[k] = v
    end
    result[:measurements_modal] = meas[:snapshot] if meas[:snapshot].present?

    result
  end
  
  private

  # Только JSON из hydration (как начало parse_html), без побочных полей.
  def parse_hydration_product_data(doc)
    product_data_attr = doc.css(".js-product-pip, [data-hydration-props]").first&.attribute("data-hydration-props")&.value

    if product_data_attr.blank?
      doc.css('script[type="text/hydration"], script[type="text/hydrate"]').each do |script|
        script_text = script.text
        if script_text.include?("packaging") && script_text.include?("product")
          product_data_attr = script_text
          break
        end
      end
    end

    if product_data_attr.blank?
      doc.css("script").each do |script|
        if script.text.include?("__FIKA_HYDRATION_DATA__")
          match = script.text.match(/window\.__FIKA_HYDRATION_DATA__\s*=\s*(\{.*?\});/m)
          product_data_attr = match[1] if match
          break
        end
      end
    end

    return nil if product_data_attr.blank?

    JSON.parse(product_data_attr.strip)
  rescue JSON::ParserError => e
    Rails.logger.debug "PlDetailsFetcher.parse_hydration_product_data: #{e.message}"
    nil
  end

  # Цена из JSON-LD только в PLN (на pl/pl витрине — злотые).
  def shelf_snapshot_pln_price_from_json_ld(schema)
    return nil unless schema.is_a?(Hash)

    offers = schema["offers"]
    return nil if offers.blank?

    flat =
      if offers.is_a?(Array)
        offers
      elsif offers.is_a?(Hash) && offers["@type"].to_s.include?("AggregateOffer")
        Array(offers["offers"])
      else
        [offers]
      end

    flat.each do |o|
      next unless o.is_a?(Hash)

      curr = (o["priceCurrency"] || o["pricecurrency"]).to_s.upcase
      next if curr.present? && curr != "PLN"

      p = o["price"]
      return p if p.present?
    end

    nil
  end

  # Цена из hydration (salesPrice / price) только при PLN или без указания валюты.
  def shelf_snapshot_pln_price_from_hydration(product_data)
    %w[salesPrice price].each do |key|
      block = product_data[key] || product_data[key.to_sym]
      next unless block.is_a?(Hash)

      curr = (block["currencyCode"] || block["currency"] || block[:currencyCode]).to_s.upcase
      next if curr.present? && curr != "PLN"

      num = block["numeral"] || block["value"] || block[:numeral]
      return num if num.present?
    end

    nil
  end

  # Decide when it makes sense to re-fetch the product page with remote
  # JavaScript rendering (scrape.do). This keeps the default path cheap/fast
  # but still recovers when IKEA returns a mostly-empty skeleton.
  def should_fallback_to_js_render?(parsed, html)
    return false unless ENV['SCRAPE_DO_API_TOKEN'].present?

    # If we don't have even the basic schema, or the page is suspiciously short.
    basic_missing = parsed.blank? || parsed[:name].blank? || parsed[:sku].blank?
    html_too_short = html.to_s.length < 5_000

    # If extended attributes are missing (common when the page is not hydrated).
    extended_missing = parsed[:description].blank? && parsed[:materials].blank? && parsed[:care_instructions].blank? && parsed[:dimensions].blank?

    basic_missing || html_too_short || extended_missing
  end

  # Choose the better parse between two versions of the same page.
  # We score by how many extended attributes are present.
  def choose_best_parse(a, b)
    return b if a.blank?
    return a if b.blank?

    score = ->(h) do
      keys = %i[description short_description materials care_instructions safety_info good_to_know dimensions package_dimensions weight]
      keys.count { |k| h[k].present? }
    end

    score_a = score.call(a)
    score_b = score.call(b)

    Rails.logger.info "PlDetailsFetcher: choose_best_parse scores - direct: #{score_a}, rendered: #{score_b}"
    score_b >= score_a ? b : a
  end

  # Fetch HTML via scrape.do with server-side JS rendering.
  # Still HTTP (no local browser), but returns hydrated DOM that often contains
  # the same data users see after clicking the UI.
  def fetch_via_scrape_do(url)
    api_token = ENV.fetch('SCRAPE_DO_API_TOKEN')
    api_url = ENV.fetch('SCRAPE_DO_API_URL', 'https://api.scrape.do/')

    ProxyRotator.with_proxy_retry do |proxy_options|
      uri = URI.parse(api_url)

      if proxy_options && proxy_options[:http_proxyaddr]
        http = Net::HTTP.new(uri.host, uri.port,
                             proxy_options[:http_proxyaddr],
                             proxy_options[:http_proxyport],
                             proxy_options[:http_proxyuser],
                             proxy_options[:http_proxypass])
      else
        http = Net::HTTP.new(uri.host, uri.port)
      end

      http.use_ssl = true
      http.read_timeout = 90
      http.open_timeout = 45

      params = {
        'token' => api_token,
        'url' => url,
        'format' => 'html',
        'render' => 'true',
        'wait' => ENV.fetch('SCRAPE_DO_WAIT_MS', '5000')
      }

      request_uri = "#{uri.path}?#{URI.encode_www_form(params)}"
      request = Net::HTTP::Get.new(request_uri)
      request['User-Agent'] = ENV.fetch('USER_AGENT', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      request['Accept-Language'] = ENV.fetch('ACCEPT_LANGUAGE', 'pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7,ru;q=0.6')

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise StandardError, "Scrape.do API error: HTTP #{response.code} #{response.message}"
      end

      response.body
    end
  rescue => e
    Rails.logger.error "PlDetailsFetcher.fetch_via_scrape_do: Failed: #{e.class} - #{e.message}"
    nil
  end
  
  def fetch_with_proxy(url)
    ProxyRotator.with_proxy_retry do |proxy_options|
      uri = URI.parse(url)
      
      if proxy_options && proxy_options[:http_proxyaddr]
        http = Net::HTTP.new(uri.host, uri.port,
                             proxy_options[:http_proxyaddr],
                             proxy_options[:http_proxyport],
                             proxy_options[:http_proxyuser],
                             proxy_options[:http_proxypass])
      else
        http = Net::HTTP.new(uri.host, uri.port)
      end
      
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 30
      
      # Use request_uri to preserve query string (uri.path would drop it)
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = ENV.fetch('USER_AGENT', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      request['Accept-Language'] = ENV.fetch('ACCEPT_LANGUAGE', 'pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7,ru;q=0.6')
      request['Accept-Encoding'] = 'gzip,deflate'
      
      response = http.request(request)

      # Follow redirects (IKEA sometimes redirects by geo/cookies)
      if response.is_a?(Net::HTTPRedirection)
        location = response['location']
        raise StandardError, "Redirect without location" if location.blank?
        return fetch_with_proxy(URI.join(url, location).to_s)
      end

      if response.is_a?(Net::HTTPSuccess)
        body = response.body

        # Decompress gzip/deflate if needed
        encoding = response['content-encoding'].to_s.downcase
        if encoding.include?('gzip')
          begin
            require 'zlib'
            require 'stringio'
            gz = Zlib::GzipReader.new(StringIO.new(body))
            body = gz.read
            gz.close
          rescue => e
            Rails.logger.warn "PlDetailsFetcher.fetch_with_proxy: Failed to gunzip response: #{e.message}"
          end
        elsif encoding.include?('deflate')
          begin
            require 'zlib'
            body = Zlib::Inflate.inflate(body)
          rescue => e
            Rails.logger.warn "PlDetailsFetcher.fetch_with_proxy: Failed to inflate response: #{e.message}"
          end
        end

        body
      else
        raise StandardError, "HTTP error: #{response.code} #{response.message}"
      end
    end
  end
  
  # Загрузка модального окна через headless браузер
  def fetch_modal_with_headless_browser(url)
    result = {}
    browser = nil
    extension_dir = nil

    proxy_options = ProxyRotator.get_proxy
    unless proxy_options
      Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: Skipping headless browser because PROXY_LIST is empty"
      return {}
    end

    browser_executable = self.class.resolved_chromium_path_for_headless
    unless browser_executable
      Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: нет исполняемого Chrome/Chromium — задайте CHROME_PATH или BROWSER_PATH (например /usr/bin/google-chrome-stable)"
      return {}
    end

    begin
      Rails.logger.info "PlDetailsFetcher.fetch_modal_with_headless_browser: Starting headless browser for #{url}"
      proxy_host = nil
      proxy_port = nil
      proxy_user = nil
      proxy_pass = nil

      case proxy_options
      when String
        s = proxy_options.strip
        s = "http://#{s}" unless s.include?("://")

        begin
          u = URI.parse(s)
          proxy_host = u.host
          proxy_port = u.port
          proxy_user = u.user
          proxy_pass = u.password
        rescue URI::InvalidURIError
          # fallback: вручную пытаемся разобрать user:pass@host:port или host:port
          s = s.sub(/\Ahttps?:\/\//, "")
          if s.include?("@")
            creds, hp = s.split("@", 2)
            proxy_user, proxy_pass = creds.split(":", 2)
            proxy_host, proxy_port = hp.split(":", 2)
          else
            proxy_host, proxy_port = s.split(":", 2)
          end
          proxy_port = proxy_port.to_i if proxy_port
        end

      when Hash
        # поддержим разные варианты ключей
        proxy_host = proxy_options[:http_proxyaddr] || proxy_options[:host]
        proxy_port = proxy_options[:http_proxyport] || proxy_options[:port]
        proxy_user = proxy_options[:http_proxyuser] || proxy_options[:user]
        proxy_pass = proxy_options[:http_proxypass] || proxy_options[:pass]

        # если вдруг server в виде строки
        if (proxy_host.blank? || proxy_port.blank?) && proxy_options[:server].present?
          s = proxy_options[:server].to_s.strip
          s = "http://#{s}" unless s.include?("://")
          u = URI.parse(s)
          proxy_host ||= u.host
          proxy_port ||= u.port
          proxy_user ||= u.user
          proxy_pass ||= u.password
        end
      end

      proxy_host = proxy_host.to_s.strip if proxy_host
      proxy_port = proxy_port.to_i if proxy_port

      proxy_string = nil
      if proxy_host.present? && proxy_port.to_i > 0
        # Chrome proxy-server должен быть ТОЛЬКО host:port
        proxy_string = "#{proxy_host}:#{proxy_port}"

        Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Using proxy for Chrome: #{proxy_string} (auth=#{proxy_user.present?})"

        if proxy_user.present? && proxy_pass.present?
          # создаём extension для прокси-авторизации
          # ИСПОЛЬЗУЕМ PROJECT TMP DIR для совместимости со Snap (используем Rails.root если доступен)
          tmp_base = defined?(Rails) ? Rails.root.join("tmp").to_s : File.join(Dir.pwd, "tmp")
          extension_dir = File.join(tmp_base, "chrome-proxy-auth-#{SecureRandom.hex(8)}")
          FileUtils.mkdir_p(extension_dir)

          manifest = {
            "version" => "1.0.0",
            "manifest_version" => 2,
            "name" => "Proxy Auth Extension",
            "permissions" => [
              "proxy",
              "tabs",
              "unlimitedStorage",
              "storage",
              "<all_urls>",
              "webRequest",
              "webRequestBlocking"
            ],
            "background" => { "scripts" => ["background.js"] },
            "minimum_chrome_version" => "22.0.0"
          }

          background = <<~JS
            var config = {
              mode: "fixed_servers",
              rules: {
                singleProxy: {
                  scheme: "http",
                  host: "#{proxy_host}",
                  port: parseInt("#{proxy_port}")
                },
                bypassList: ["localhost", "127.0.0.1"]
              }
            };

            chrome.proxy.settings.set({value: config, scope: "regular"}, function() {});

            function callbackFn(details) {
              return {
                authCredentials: {
                  username: "#{proxy_user}",
                  password: "#{proxy_pass}"
                }
              };
            }

            chrome.webRequest.onAuthRequired.addListener(
              callbackFn,
              {urls: ["<all_urls>"]},
              ["blocking"]
            );
          JS

          File.write(File.join(extension_dir, "manifest.json"), JSON.pretty_generate(manifest))
          File.write(File.join(extension_dir, "background.js"), background)
        end
      else
        Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: Proxy host/port missing"
        return {}
      end

      browser_options = {
        "no-sandbox" => nil,
        "disable-dev-shm-usage" => nil,
        "disable-gpu" => nil,
        "disable-software-rasterizer" => nil,
        "disable-extensions" => nil, # <-- ВАЖНО: ЭТУ СТРОКУ НЕЛЬЗЯ оставлять, если мы грузим extension
        "disable-background-networking" => nil,
        "disable-background-timer-throttling" => nil,
        "disable-backgrounding-occluded-windows" => nil,
        "disable-breakpad" => nil,
        "disable-client-side-phishing-detection" => nil,
        "disable-default-apps" => nil,
        "disable-hang-monitor" => nil,
        "disable-popup-blocking" => nil,
        "disable-prompt-on-repost" => nil,
        "disable-sync" => nil,
        "disable-translate" => nil,
        "metrics-recording-only" => nil,
        "no-first-run" => nil,
        "safebrowsing-disable-auto-update" => nil,
        "password-store=basic" => nil,
        "use-mock-keychain" => nil,
        "window-size" => "1366,768"
      }

      # ВАЖНО:
      # если extension_dir есть — НЕ надо включать "disable-extensions"
      # иначе Chrome просто не загрузит auth-extension
      if extension_dir
        browser_options.delete("disable-extensions")
      end

      browser_options["proxy-server"] = proxy_string if proxy_string

      if extension_dir
        browser_options["load-extension"] = extension_dir
        browser_options["disable-extensions-except"] = extension_dir
      end

      # ИСПОЛЬЗУЕМ headless=new для поддержки расширений в headless режиме
      if full_browser_mode?
        Rails.logger.info "PlDetailsFetcher.fetch_modal_with_headless_browser: Running in full browser mode (headless disabled)"
      else
        browser_options["headless"] = "new"
      end

      opts = {
        headless: false, # Отключаем стандартный флаг --headless, используем --headless=new через browser_options
        timeout: 60,
        browser_path: browser_executable
      }

      browser = Ferrum::Browser.new(browser_options: browser_options, **opts)
      
      # Устанавливаем User-Agent для обхода защиты
      browser.headers.set({
        'User-Agent' => ENV.fetch('USER_AGENT', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'),
        'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language' => 'pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7',
        'Accept-Encoding' => 'gzip, deflate, br',
        'Connection' => 'keep-alive',
        'Upgrade-Insecure-Requests' => '1',
        'Sec-Fetch-Dest' => 'document',
        'Sec-Fetch-Mode' => 'navigate',
        'Sec-Fetch-Site' => 'none',
        'Cache-Control' => 'max-age=0'
      })
      
      # Загружаем страницу
      browser.go_to(url)
      
      # Ждем загрузки страницы и прохождения Cloudflare проверки
      browser.network.wait_for_idle(timeout: 20)
      sleep(5) # Дополнительная пауза для прохождения Cloudflare и загрузки динамического контента
      
      # Проверяем, не попали ли мы на страницу Cloudflare
      page_html = browser.body
      if page_html.length < 10000 || page_html.include?('Cloudflare') || page_html.include?('Just a moment')
        Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: Possible Cloudflare protection, waiting longer..."
        sleep(10) # Ждем прохождения Cloudflare проверки
        page_html = browser.body
      end
      
      Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Page loaded, HTML length: #{page_html.length}"
      
      # Ищем кнопку для открытия модального окна "Информация о продукте"
      modal_opened = false
      
      # Пробуем открыть через JavaScript (более надежно)
      begin
        button_info = browser.evaluate(<<~JS)
          (function() {
            // Ищем кнопку "Информация о продукте"
            const buttons = Array.from(document.querySelectorAll('button, a'));
            const infoButton = buttons.find(btn => {
              const text = btn.textContent || '';
              const id = btn.closest('[id*="pipf-product-information-section-list-0"]');
              const ariaControls = btn.getAttribute('aria-controls');
              return text.includes('Информация о продукте') || 
                     text.includes('Informacja o produkcie') ||
                     (ariaControls && ariaControls.includes('product-details')) ||
                     id !== null;
            });
            if (infoButton) {
              return {
                found: true,
                text: infoButton.textContent,
                id: infoButton.id,
                className: infoButton.className
              };
            }
            return { found: false, buttonsCount: buttons.length };
          })();
        JS
        
        if button_info && button_info['found']
          Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Found button via JS: #{button_info['text']}"
          clicked = browser.evaluate(<<~JS)
            (function() {
              const buttons = Array.from(document.querySelectorAll('button, a'));
              const infoButton = buttons.find(btn => {
                const text = btn.textContent || '';
                const id = btn.closest('[id*="pipf-product-information-section-list-0"]');
                const ariaControls = btn.getAttribute('aria-controls');
                return text.includes('Информация о продукте') || 
                       text.includes('Informacja o produkcie') ||
                       (ariaControls && ariaControls.includes('product-details')) ||
                       id !== null;
              });
              if (infoButton) {
                infoButton.click();
                return true;
              }
              return false;
            })();
          JS
          modal_opened = clicked if clicked
          Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Button clicked: #{modal_opened}"
        else
          Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Button not found via JS. Buttons count: #{button_info ? button_info['buttonsCount'] : 'unknown'}"
        end
        sleep(2) if modal_opened
      rescue => e
        Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Error opening modal via JS: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
      
      # Если не открылось через JS, пробуем через CSS селекторы
      unless modal_opened
        modal_button_selectors = [
          '[id*="pipf-product-information-section-list-0"] button',
          'button[aria-controls*="product-details"]',
          '.pipf-list-view-item__action',
          '#pipf-product-information-section-list-0 button'
        ]
        
        modal_button_selectors.each do |selector|
          begin
            button = browser.at_css(selector)
            if button
              Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Found button with selector: #{selector}"
              button.click
              sleep(2)
              modal_opened = true
              break
            end
          rescue => e
            Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Error clicking button: #{e.message}"
            next
          end
        end
      end
      
      # Ждем появления модального окна (проверяем явно)
      if modal_opened
        Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Waiting for modal to appear..."
        # Ждем до 5 секунд появления модального окна
        10.times do |i|
          sleep(0.5)
          modal_exists = browser.evaluate(<<~JS)
            (function() {
              return document.querySelector('.pipf-product-details-modal, [aria-modal="true"], [id*="product-details"]') !== null;
            })();
          JS
          if modal_exists
            Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Modal appeared after #{i * 0.5} seconds"
            break
          end
        end
        sleep(1) # Дополнительная пауза для полной загрузки контента модального окна
      else
        Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: Modal button was not clicked, trying to extract from page anyway"
      end

      # Модалка «Elementy w zestawie» — только после клика по строке списка (sheet).
      included_skus = try_open_included_products_sheet!(browser) || []
      
      # Получаем HTML страницы после открытия модального окна
      page_html = browser.body
      Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Final HTML length: #{page_html.length}"
      modal_doc = Nokogiri::HTML(page_html)
      
      # Проверяем наличие модального окна в HTML
      modal_found = modal_doc.css('.pipf-product-details-modal, [aria-modal="true"], [id*="product-details"]').any?
      Rails.logger.debug "PlDetailsFetcher.fetch_modal_with_headless_browser: Modal found in HTML: #{modal_found}"
      
      # Извлекаем данные из модального окна
      pd_headless = parse_hydration_product_data(modal_doc)
      result = extract_modal_details(modal_doc, pd_headless)
      result[:included_products] = included_skus if included_skus.present?

      Rails.logger.info "PlDetailsFetcher.fetch_modal_with_headless_browser: Extracted - materials: #{result[:materials].present?}, care: #{result[:care_instructions].present?}, safety: #{result[:safety_info].present?}, good_to_know: #{result[:good_to_know].present?}, included_products: #{included_skus&.length || 0}"
      
      result
      
    rescue Ferrum::BinaryNotFoundError => e
      Rails.logger.warn "PlDetailsFetcher.fetch_modal_with_headless_browser: #{e.class} — #{e.message.strip} (CHROME_PATH / BROWSER_PATH)"
      {}
    rescue Ferrum::StatusError => e
      Rails.logger.error "PlDetailsFetcher.fetch_modal_with_headless_browser: Error: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      {}
    rescue => e
      Rails.logger.error "PlDetailsFetcher.fetch_modal_with_headless_browser: Error: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      {}
    ensure
      if browser
        begin
          browser.quit
        rescue
          # ignore
        end
      end

      if extension_dir && Dir.exist?(extension_dir)
        FileUtils.rm_rf(extension_dir)
      end
    end
  end
  
  def extract_json_ld(doc)
    doc.css('script[type="application/ld+json"]').each do |script|
      begin
        data = JSON.parse(script.text)
        return data if data['@type'] == 'Product'
      rescue JSON::ParserError
        next
      end
    end
    nil
  end
  
  def extract_set_items(product_data, doc)
    possible_paths = [
      product_data&.dig('productSetSection', 'items'),
      product_data&.dig('setSection', 'items'),
      product_data&.dig('setItems'),
      product_data&.dig('productSet', 'items')
    ]
    
    items = []
    possible_paths.each do |path|
      if path.is_a?(Array) && path.any?
        items = path.map { |item| item['itemNo'] || item['itemNoGlobal'] || item }
                    .compact
                    .select { |item_no| item_no.to_s.match?(/^[0-9a-zA-Z]+$/) }
        break if items.any?
      end
    end
    
    # Если не нашли в JSON, пробуем HTML
    if items.empty?
      doc.css('.pip-product-set-section, .pip-set-items').each do |section|
        section.css('[data-item-no], .pip-item-no').each do |el|
          item_no = el['data-item-no'] || el.text.strip
          items << item_no if item_no.match?(/^[0-9a-zA-Z]+$/)
        end
      end
    end
    
    items.uniq
  end
  
  def extract_related_products(product_data, doc = nil)
    unless Products::RelatedProductsCollection::ENABLED
      Rails.logger.debug "PlDetailsFetcher.extract_related_products: skipped (RelatedProductsCollection::ENABLED is false)"
      return []
    end

    related = []
    
    Rails.logger.debug "PlDetailsFetcher.extract_related_products: Starting extraction"
    
    if product_data
      # Список всех возможных путей для связанных продуктов (как в JS-парсере)
      paths_to_check = [
        # Основные пути
        ['addOns', 'addOns'],
        ['addOns'],
        ['recommendedProducts'],
        ['recommended', 'products'],
        ['relatedProducts'],
        ['related', 'products'],
        ['productSuggestions'],
        ['suggestions'],
        ['productRecommendations'],
        ['recommendations'],
        ['suggestedProducts'],
        ['youMightAlsoLike'],
        ['complementaryProducts'],
        ['accessories'],
        ['accessoryProducts'],
        ['completeTheLook'],
        ['completeTheLookProducts'],
        ['frequentlyBoughtTogether'],
        ['boughtTogether'],
        ['similarProducts'],
        ['similar'],
        ['alternatives'],
        ['alternativeProducts'],
        # Вложенные пути
        ['productInformationSection', 'relatedProducts'],
        ['productInformationSection', 'recommendedProducts'],
        ['productInformationSection', 'accessories'],
        ['mediaSection', 'relatedProducts'],
        ['mediaSection', 'recommendedProducts'],
        ['productDetails', 'relatedProducts'],
        ['productDetails', 'recommendedProducts'],
        ['productDetails', 'accessories']
      ]
      
      paths_to_check.each do |path|
        items = product_data.dig(*path)
        next unless items.present?
        
        Rails.logger.debug "PlDetailsFetcher.extract_related_products: Checking path #{path.join('.')}: #{items.class}"
        
        # Обрабатываем массив
        if items.is_a?(Array)
          items.each do |item|
            item_no = extract_item_no_from_hash(item)
            if item_no.present?
              related << item_no.to_s
              Rails.logger.debug "PlDetailsFetcher.extract_related_products: Added from #{path.join('.')}: #{item_no}"
            end
          end
        # Обрабатываем объект с вложенными массивами
        elsif items.is_a?(Hash)
          # Ищем вложенные массивы items, products, etc.
          ['items', 'products', 'productsList', 'list'].each do |key|
            nested_items = items[key] || items[key.to_sym]
            if nested_items.is_a?(Array)
              nested_items.each do |item|
                item_no = extract_item_no_from_hash(item)
                if item_no.present?
                  related << item_no.to_s
                  Rails.logger.debug "PlDetailsFetcher.extract_related_products: Added from #{path.join('.')}.#{key}: #{item_no}"
                end
              end
            end
          end
          
          # Если сам объект содержит itemNo
          item_no = extract_item_no_from_hash(items)
          if item_no.present?
            related << item_no.to_s
            Rails.logger.debug "PlDetailsFetcher.extract_related_products: Added from #{path.join('.')} (direct): #{item_no}"
          end
        end
      end
      
      # Рекурсивный поиск в productData (на случай, если структура изменилась)
      find_related_in_hash(product_data, related)
    end
    
    # Извлечение из HTML (если есть doc)
    if doc
      # Расширенный список селекторов для связанных продуктов
      html_selectors = [
        '.pip-product-recommendations [data-item-no]',
        '.pip-related-products [data-item-no]',
        '.pip-recommendation [data-item-no]',
        '[data-product-id]',
        '[data-item-no]',
        '[data-sku]',
        '.pip-accessories [data-item-no]',
        '.pip-complete-the-look [data-item-no]',
        '.pip-frequently-bought-together [data-item-no]',
        '.product-recommendation [data-item-no]',
        'a[href*="/p/"]'
      ]
      
      html_related = doc.css(html_selectors.join(', '))
      Rails.logger.debug "PlDetailsFetcher.extract_related_products: Found #{html_related.length} HTML elements with related products"
      
      html_related.each do |el|
        # Из data-атрибутов
        item_no = el['data-item-no'] || el['data-product-id'] || el['data-sku'] || el['data-item-no-global']
        
        # Из href (формат: /pl/pl/p/{item_no}/)
        if item_no.blank? && el['href']
          match = el['href'].match(%r{/p/([^/]+)/?})
          item_no = match[1] if match
        end
        
        if item_no.present?
          related << item_no
          Rails.logger.debug "PlDetailsFetcher.extract_related_products: Added from HTML: #{item_no}"
        end
      end
    end
    
    result = related.filter_map { |x| normalize_product_token(x) }.uniq
    Rails.logger.info "PlDetailsFetcher.extract_related_products: Extracted #{result.length} related products"
    result
  end

  # На PIPF кнопка строки списка с заголовком «Elementy w zestawie» (и аналоги) — без SSR-модалки состава.
  def included_products_sheet_clickable?(doc)
    return false unless doc

    doc.css("button.pipf-list-view-item__action").any? do |btn|
      txt = btn.text.to_s.downcase
      txt.include?("elementy w zestawie") ||
        txt.match?(/elements?\s+in\s+the\s+package|items\s+in\s+the\s+set/) ||
        txt.match?(/элементы|входит\s+в\s+комплект/) ||
        txt.include?("bestanddelen") ||
        txt.include?("komponenty")
    end
  end

  # Headless: клик по строке «Elementy w zestawie» → sheet с .pipf-included-products-modal.
  def try_open_included_products_sheet!(browser)
    clicked = browser.evaluate(<<~'JS')
      (function() {
        const buttons = Array.from(document.querySelectorAll("button.pipf-list-view-item__action"));
        const re = /elementy\\s+w\\s+zestawie|elements?\\s+in\\s+the\\s+package|items\\s+in\\s+the\\s+set|komponenty|bestanddelen|элементы|в\\s+комплект/i;
        const target = buttons.find(function(b) { return re.test((b.innerText || "").trim()); });
        if (!target) { return false; }
        try { target.scrollIntoView({ block: "center", inline: "nearest" }); } catch (e) {}
        target.click();
        return true;
      })();
    JS

    return [] unless clicked

    24.times do
      sleep(0.35)
      open = browser.evaluate(<<~'JS')
        (function() {
          return document.querySelector(".pipf-included-products-modal__list li, .pipf-included-products-modal a[href*='/p/']") !== null;
        })();
      JS
      return extract_included_products(nil, Nokogiri::HTML(browser.body)) if open
    end

    extract_included_products(nil, Nokogiri::HTML(browser.body))
  rescue StandardError => e
    Rails.logger.debug "PlDetailsFetcher.try_open_included_products_sheet!: #{e.message}"
    []
  end

  # Только модалка «Elementy w zestawie» / pipf-included-products-modal (см. PIPF list view + sheet).
  # Не берём subProducts / JSON — там смешиваются варианты и прочие сущности.
  def extract_included_products(_product_data, doc)
    modal_root = doc.at_css(".pipf-included-products-modal")
    return [] unless modal_root

    items = []

    modal_root.css("a[href*='/p/']").each do |el|
      next unless el["href"].present?

      m = el["href"].to_s.match(/-([a-z0-9]{8,9})\/?$/i)
      token = m&.[](1)
      norm = normalize_product_token(token)
      items << norm if norm.present?
    end

    modal_root.css(".pipf-product-identifier__value").each do |el|
      compact = el.text.to_s.gsub(/[^0-9a-z]/i, "").downcase
      norm = normalize_product_token(compact)
      items << norm if norm.present?
    end

    modal_root.css("[data-item-no], [data-product-id], [data-sku]").each do |el|
      token = el["data-item-no"] || el["data-product-id"] || el["data-sku"]
      norm = normalize_product_token(token)
      items << norm if norm.present?
    end

    items.uniq
  end

  def extract_variants(product_data, doc)
    variants = []

    raw_candidates = [
      product_data&.dig("gprDescription", "variants"),
      product_data&.dig("variants"),
      product_data&.dig("variantSection", "items"),
      product_data&.dig("productDetails", "variants"),
      product_data&.dig("pageProps", "product", "subProducts")
    ].compact

    raw_candidates.each do |candidate|
      Array(candidate).each do |entry|
        token =
          if entry.is_a?(Hash)
            entry["itemNo"] || entry["itemNoGlobal"] || entry["visibleItemNo"] || entry["articleNumber"] || entry["sku"] || entry["id"] || entry["value"]
          else
            entry
          end
        if token.blank? && entry.is_a?(Hash) && entry["pipUrl"].present?
          m = entry["pipUrl"].to_s.match(/-([a-z0-9]{8,9})\/?$/i)
          token = m[1] if m
        end
        norm = normalize_product_token(token)
        next if norm.blank?
        variants << { "sku" => norm }
      end
    end

    doc.css(".pipf-variant-picker a[href*='/p/'], [data-testid*='variant'] a[href*='/p/']").each do |a|
      m = a["href"].to_s.match(/-([a-z0-9]{8,9})\/?$/i)
      next unless m
      norm = normalize_product_token(m[1])
      variants << { "sku" => norm } if norm.present?
    end

    variants.uniq { |v| v["sku"] }
  end

  # Сегменты заголовка в блоке цены PIPCOM (LT/PL и др.): имя без варианта/размеров и строка «цвет, размер».
  def extract_pipcom_product_heading_parts(doc)
    return { name: nil, small_desc_name: nil } unless doc

    name_el = doc.at_css(".pipcom-price-module__name-decorator")
    main_name = normalize_pipcom_heading_text(name_el&.text)

    desc_el = doc.at_css(".pipcom-price-module__description")
    small_desc = normalize_pipcom_heading_text(desc_el&.text)

    { name: main_name, small_desc_name: small_desc }
  end

  def normalize_pipcom_heading_text(text)
    s = text.to_s.gsub(/\s+/, " ").strip
    s.presence
  end

  def extract_small_desc_name(product_data, doc)
    from_html = normalize_pipcom_heading_text(doc.at_css(".pipcom-price-module__description")&.text)
    return from_html if from_html.present?

    from_data =
      product_data&.dig("itemMeasureReferenceText") ||
      product_data&.dig("product", "itemMeasureReferenceText") ||
      product_data&.dig("gprDescription", "itemMeasureReferenceText")
    from_data.to_s.strip.presence
  end

  def normalize_product_token(value)
    token = value.to_s.strip
    return nil if token.blank?
    compact = token.gsub(/[^0-9a-z]/i, "").downcase
    return nil if compact.blank?
    return compact if compact.match?(/\A\d{8}\z/)
    return compact if compact.match?(/\As\d{8}\z/)
    nil
  end
  
  # Вспомогательный метод для извлечения item_no из объекта
  def extract_item_no_from_hash(item)
    return nil unless item.is_a?(Hash)
    
    # Проверяем различные возможные поля
    item_no = item['itemNo'] || 
              item['itemNoGlobal'] || 
              item['item_no'] ||
              item['item_no_global'] ||
              item['id'] ||
              item['sku'] ||
              item['productId'] ||
              item['product_id'] ||
              item[:itemNo] ||
              item[:itemNoGlobal] ||
              item[:id] ||
              item[:sku]
    
    # Если item_no найден, проверяем тип (берем только товары, не категории)
    if item_no.present?
      item_type = item['itemType'] || item['type'] || item['item_type'] || item[:itemType] || item[:type]
      # Пропускаем категории и другие типы, если указан тип
      if item_type.present? && item_type != 'ART' && item_type != 'PRODUCT'
        return nil
      end
    end
    
    item_no
  end
  
  # Рекурсивный поиск связанных продуктов в хеше
  def find_related_in_hash(hash, related, depth = 0)
    return if depth > 5  # Ограничиваем глубину рекурсии
    
    case hash
    when Hash
      # Проверяем, не является ли это объектом продукта
      if hash['itemNo'] || hash['itemNoGlobal'] || hash['id'] || hash['sku']
        item_no = extract_item_no_from_hash(hash)
        if item_no.present? && !related.include?(item_no.to_s)
          related << item_no.to_s
          Rails.logger.debug "PlDetailsFetcher.find_related_in_hash: Found item_no: #{item_no}"
        end
      end
      
      # Рекурсивно обходим значения
      hash.each_value { |v| find_related_in_hash(v, related, depth + 1) }
    when Array
      hash.each { |item| find_related_in_hash(item, related, depth + 1) }
    end
  end
  
  def extract_packaging_info(doc, product_data)
    result = {}
    
    Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Starting extraction"
    
    # Расширенный список путей для информации об упаковке (как в JS-парсере)
    packaging_paths = [
      ['stockcheckSection', 'packagingProps', 'packages'],
      ['stockcheckSection', 'packaging', 'packages'],
      ['pageProps', 'product', 'packaging', 'packages'],
      ['packaging', 'contentProps', 'packages'],
      ['packaging', 'packages'],
      ['packagingProps', 'packages'],
      ['packages'],
      ['productInformationSection', 'packaging', 'packages'],
      ['productInformationSection', 'packagingProps', 'packages'],
      ['productDetails', 'packaging', 'packages'],
      ['productDetails', 'packagingProps', 'packages'],
      ['specifications', 'packaging', 'packages'],
      ['specifications', 'packagingProps', 'packages']
    ]
    
    packaging = nil
    packaging_paths.each do |path|
      packaging = product_data&.dig(*path)
      if packaging.present?
        Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found packaging at path: #{path.join('.')}"
        break
      end
    end
    
    # Дополнительная проверка для нового формата, если через dig не нашли
    if packaging.nil? && product_data&.dig('pageProps', 'product').is_a?(Hash)
      p_data = product_data.dig('pageProps', 'product')
      packaging = p_data['packaging']&.dig('packages') || p_data['packaging']
    end

    Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: packaging found: #{packaging.present?}, type: #{packaging.class}, count: #{packaging.is_a?(Array) ? packaging.size : 'N/A'}"
    
    if packaging.is_a?(Array) && packaging.any?
      # Общий вес - сумма всех упаковок (в килограммах)
      total_weight = 0
      packaging.each do |pkg|
        # 1. Пробуем найти вес в measurements (массив упаковок)
        pkg_total_weight = 0
        found_pkg_weight = false
        
        if pkg['measurements'].is_a?(Array)
          # measurements может быть [[{type: 'weight', value: 36.7}], [{type: 'weight', value: 32.3}]]
          pkg['measurements'].each do |m_group|
            m_group = [m_group] unless m_group.is_a?(Array)
            m_group.each do |m|
              if m.is_a?(Hash) && (m['type'] == 'weight' || m[:type] == 'weight' || m['label']&.downcase&.include?('вес'))
                weight = m['value'] || m[:value]
                if weight.present?
                  pkg_total_weight += weight.to_f
                  found_pkg_weight = true
                end
              end
            end
          end
        end
        
        # 2. Если в measurements не нашли, пробуем прямые поля
        if !found_pkg_weight
          weight = pkg['weight'] || pkg[:weight] || pkg['weightKg'] || pkg[:weightKg]
          if weight.present?
            pkg_total_weight = weight.to_f
            found_pkg_weight = true
          end
        end
        
        # 3. Количество этих предметов (например, 2 подлокотника)
        qty = pkg.dig('quantity', 'value') || pkg.dig(:quantity, :value) || 1
        
        total_weight += pkg_total_weight * qty.to_i if found_pkg_weight
      end
      result[:weight] = total_weight.round(2) if total_weight > 0
      Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Total weight from product_data: #{result[:weight]}"
      
      # Обрабатываем все упаковки для получения полной информации
      packaging.each_with_index do |pkg, idx|
        # Чистый вес (netWeight) - берем из первой упаковки, если не указан
        if result[:net_weight].blank?
          net_weight = pkg['netWeight'] || pkg[:netWeight] || pkg['net_weight'] || pkg['netWeightKg'] || pkg[:netWeightKg]
          if net_weight
            result[:net_weight] = net_weight.to_f
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Net weight from package #{idx}: #{result[:net_weight]}"
          end
        end
        
        # Объём упаковки - берем из первой упаковки
        if result[:package_volume].blank?
          volume = pkg['volume'] || pkg[:volume] || pkg['volumeL'] || pkg[:volumeL] || pkg['volumeM3'] || pkg[:volumeM3]
          if volume
            # Если объём в м³, конвертируем в литры
            volume_value = volume.to_f
            volume_value *= 1000 if pkg['volumeM3'] || pkg[:volumeM3]  # м³ в литры
            result[:package_volume] = volume_value
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Package volume from package #{idx}: #{result[:package_volume]}"
          end
        end
        
        # Размеры упаковки (package_dimensions)
        if result[:package_dimensions].blank?
          measurements = pkg['measurements'] || pkg[:measurements] || pkg['packageMeasurements'] || pkg[:packageMeasurements]
          if measurements.is_a?(Hash)
            width = measurements['width'] || measurements[:width] || measurements['w']
            height = measurements['height'] || measurements[:height] || measurements['h']
            length = measurements['length'] || measurements[:length] || measurements['l'] || measurements['depth'] || measurements[:depth]
            if width && height && length
              result[:package_dimensions] = "#{width} × #{height} × #{length}"
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Package dimensions from package #{idx}: #{result[:package_dimensions]}"
            end
          end
        end
        
        # Размеры продукта (dimensions) - берем из первой упаковки
        if result[:dimensions].blank?
          dimensions = pkg['dimensions'] || pkg[:dimensions] || pkg['productDimensions'] || pkg[:productDimensions]
          if dimensions.is_a?(Hash)
            width = dimensions['width'] || dimensions[:width] || dimensions['w']
            height = dimensions['height'] || dimensions[:height] || dimensions['h']
            length = dimensions['length'] || dimensions[:length] || dimensions['l'] || dimensions['depth'] || dimensions[:depth]
            if width && height && length
              result[:dimensions] = "#{width} × #{height} × #{length}"
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Product dimensions from package #{idx}: #{result[:dimensions]}"
            end
          end
        end
        
        # Если нашли все необходимые данные, можно прервать цикл
        break if result[:net_weight].present? && result[:package_volume].present? && 
                result[:package_dimensions].present? && result[:dimensions].present?
      end
    end
    
    # Если не нашли в packaging, пробуем прямые пути в productData
    if result[:weight].blank?
      weight_paths = [
        ['weight'],
        ['weightKg'],
        ['productWeight'],
        ['totalWeight'],
        ['stockcheckSection', 'weight'],
        ['productInformationSection', 'weight']
      ]
      
      weight_paths.each do |path|
        weight = product_data&.dig(*path)
        if weight
          result[:weight] = weight.to_f
          Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Weight from #{path.join('.')}: #{result[:weight]}"
          break
        end
      end
    end
    
    # Если не нашли в productData, пробуем извлечь из HTML (улучшенный парсинг)
    if result[:weight].blank? || result[:dimensions].blank? || result[:package_dimensions].blank?
      Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Trying to extract from HTML"
      
      # 1. Сначала ищем именно "Информацию об упаковке" (самый надежный источник для суммы)
      # Ищем по ключевым словам в заголовках или секциях
      packaging_info_section = nil
      doc.css('.pip-product-details__section, .pip-specifications__section, [data-section], section, div, h2, h3, h4').each do |el|
        text = el.text.strip.downcase
        if text == 'информация об упаковке' || text == 'informacja o opakowaniu' || text == 'packaging information'
          # Берем родительский контейнер или следующий элемент
          packaging_info_section = el.parent if el.name.start_with?('h')
          packaging_info_section ||= el
          break
        end
      end

      if packaging_info_section
        Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found explicit packaging info section"
        total_weight = 0
        found_any_weight = false
        
        # Нормализуем текст
        text_content = packaging_info_section.text.gsub("\u00A0", " ").gsub(/\s+/, " ")
        
        # Разбиваем на блоки по слову "Вес" (или аналогам), чтобы правильно привязать количество к весу
        # Используем позитивную опережающую проверку (?=...), чтобы слово "Вес" осталось в начале блока
        parts = text_content.split(/(?=вес|waga|weight)/i)
        
        parts.each do |part|
          # Ищем вес в этом блоке
          if part.match(/(?:вес|waga|weight)[:\s]+([\d,\.]+)\s*(?:kg|кг)/i)
            weight_val = $1.gsub(',', '.').to_f
            
            # Ищем количество в этом же блоке (после веса, но до следующего веса)
            qty_match = part.match(/(?:упаковка|opakowanie|paczka|package).*?(\d+)/i)
            qty = qty_match ? qty_match[1].to_i : 1
            
            total_weight += weight_val * qty
            found_any_weight = true
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: HTML part weight: #{weight_val} kg x #{qty}"
          end
        end
        
        if found_any_weight && total_weight > 0 && result[:weight].blank?
          result[:weight] = total_weight.round(2)
          Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Final summed weight from section: #{result[:weight]} kg"
        end
      end

      # 2. Если вес все еще пуст, ищем в общих секциях, исключая "нагрузку"
      if result[:weight].blank?
        packaging_sections = doc.css('.pip-product-details__section, .pip-specifications__section, [data-section], section, div, li, ul').select do |section|
          section_text = section.text.downcase
          (section_text.include?('opakowanie') || section_text.include?('paczk') || section_text.include?('paczka') || section_text.include?('упаковка') || section_text.include?('пакет')) &&
          (section_text.include?('kg') || section_text.include?('кг') || section_text.include?('waga') || section_text.include?('вес') || section_text.include?('cm') || section_text.include?('см'))
        end
        
        if packaging_sections.any?
          weights_found = []
          packaging_sections.each do |section|
            # Ищем веса, исключая строки с "нагрузкой"
            section.text.each_line do |line|
              next if line.downcase.match?(/нагрузка|load|obciążenie|obciazenie|nośność|nosnosc|obciążenia|obciazenia/)
              
              line.scan(/([\d,\.]+)\s*(kg|кг)/i) do |match|
                weight_value = match[0].gsub(',', '.').to_f
                if weight_value >= 0.1 && weight_value <= 500
                  weights_found << weight_value unless weights_found.include?(weight_value)
                end
              end
            end
          end
          
          if weights_found.any?
            result[:weight] = weights_found.max.round(2)
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found max weight in sections: #{result[:weight]} kg"
          end
        end
      end

      # 3. Крайний случай - поиск по всей странице, исключая нагрузку
      if result[:weight].blank?
        doc.text.each_line do |line|
          next if line.downcase.match?(/нагрузка|load|obciążenie|obciazenie|nośność|nosnosc|obciążenia|obciazenia|полку|polce|półce|półку/)
          
          line.scan(/([\d,\.]+)\s*(kg|кг)/i) do |match|
            weight_value = match[0].gsub(',', '.').to_f
            if weight_value >= 0.1 && weight_value <= 500
              result[:weight] = weight_value.round(2)
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found weight in global text line: #{result[:weight]} kg"
              break
            end
          end
          break if result[:weight].present?
        end
      end
      
      # Ищем размеры продукта в секции "Wymiary" или в таблицах
      doc.css('.pip-product-details__section, .pip-specifications__section, [data-dimensions]').each do |section|
        section_text = section.text.downcase
        
        if section_text.include?('wymiary') || section_text.include?('rozmiar') || section_text.include?('wymiar') || section_text.include?('размеры') || section_text.include?('размер')
          Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found dimensions section"
          
          # Извлекаем размеры продукта
          if result[:dimensions].blank?
            # Пробуем найти в тексте (например, "Szerokość: 199 cm, Głębokość: 93 cm, Высота: 70 cm")
            width = section.text.match(/(?:szerokość|ширина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
            depth = section.text.match(/(?:głębokość|глубина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
            height = section.text.match(/(?:wysokość|высота)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
            
            if width && depth && height
              result[:dimensions] = "#{width.gsub(',', '.')} × #{depth.gsub(',', '.')} × #{height.gsub(',', '.')} cm"
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Product dimensions from dimensions section: #{result[:dimensions]}"
            end
          end
        end
      end
      
      # Ищем в таблицах характеристик (более агрессивный поиск)
      doc.css('table, .pip-product-details-table, .pip-specifications-table, dl, .specification-list').each do |table|
        table.css('tr, dt, .specification-item').each do |row|
          label = (row.css('th, dt, .spec-label, [data-label]').first || row.css('td, dd').first)&.text&.strip&.downcase
          value = (row.css('td:last-child, dd, .spec-value, [data-value]').first || row.css('td').last)&.text&.strip
          
          next unless label && value
          
          # Вес (Waga/Вес)
          if result[:weight].blank? && (label.include?('waga') || label.include?('weight') || label.include?('masa') || label.include?('вес'))
            weight_match = value.match(/([\d,\.]+)\s*(kg|кг|g|г)/i)
            if weight_match
              weight_value = weight_match[1].gsub(',', '.').to_f
              weight_value /= 1000 if value.match?(/g|г/i) && !value.match?(/kg|кг/i)
              result[:weight] = weight_value
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Weight from table: #{result[:weight]}"
            end
          end
          
          # Чистый вес (Waga netto/Вес нетто)
          if result[:net_weight].blank? && (label.include?('waga netto') || label.include?('net weight') || label.include?('netto') || label.include?('нетто'))
            weight_match = value.match(/([\d,\.]+)\s*(kg|кг|g|г)/i)
            if weight_match
              weight_value = weight_match[1].gsub(',', '.').to_f
              weight_value /= 1000 if value.match?(/g|г/i) && !value.match?(/kg|кг/i)
              result[:net_weight] = weight_value
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Net weight from table: #{result[:net_weight]}"
            end
          end
          
          # Объём (Objętość/Объем)
          if result[:package_volume].blank? && (label.include?('objętość') || label.include?('volume') || label.include?('pojemność') || label.include?('объем'))
            volume_match = value.match(/([\d,\.]+)\s*(l|л|м³|m³|litr)/i)
            if volume_match
              volume_value = volume_match[1].gsub(',', '.').to_f
              volume_value *= 1000 if value.match?(/м³|m³/i)  # м³ в литры
              result[:package_volume] = volume_value
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Volume from table: #{result[:package_volume]}"
            end
          end
          
          # Размеры продукта (Wymiary produktu/Размеры товара)
          if result[:dimensions].blank? && (label.include?('wymiary produktu') || label.include?('wymiary') || label.include?('rozmiar') || label.include?('размеры'))
            # Пробуем извлечь из значения
            dims_match = value.match(/([\d,\.]+)\s*[×x]\s*([\d,\.]+)\s*[×x]\s*([\d,\.]+)/i)
            if dims_match
              result[:dimensions] = "#{dims_match[1].gsub(',', '.')} × #{dims_match[2].gsub(',', '.')} × #{dims_match[3].gsub(',', '.')}"
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Dimensions from table: #{result[:dimensions]}"
            end
          end
          
          # Размеры упаковки (Wymiary opakowania/Размеры упаковки)
          if result[:package_dimensions].blank? && (label.include?('wymiary opakowania') || label.include?('rozmiar opakowania') || label.include?('package') || label.include?('упаковка'))
            dims_match = value.match(/([\d,\.]+)\s*[×x]\s*([\d,\.]+)\s*[×x]\s*([\d,\.]+)/i)
            if dims_match
              result[:package_dimensions] = "#{dims_match[1].gsub(',', '.')} × #{dims_match[2].gsub(',', '.')} × #{dims_match[3].gsub(',', '.')}"
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Package dimensions from table: #{result[:package_dimensions]}"
            end
          end
        end
      end
      
      # Дополнительный поиск в тексте страницы (regex поиск)
      page_text = doc.text
      
      # Ищем вес в тексте (например, "Waga: 37.55 kg" или "Вес: 37.55 кг")
      if result[:weight].blank?
        # Паттерн 1: "Waga: 37.55 kg" или "Вес: 37.55 кг"
        page_text.scan(/(?:waga|weight|masa|вес)[:\s]+([\d,\.]+)\s*(kg|кг)/i) do |match|
          weight_value = match[0].gsub(',', '.').to_f
          # Берем первый найденный вес в разумном диапазоне (от 0.1 до 500 кг)
          if weight_value >= 0.1 && weight_value <= 500
            result[:weight] = weight_value.round(2)
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Weight from page text (pattern 1): #{result[:weight]} kg"
            break
          end
        end
        
        # Паттерн 2: Первый найденный вес в разумном диапазоне (вес с упаковкой)
        if result[:weight].blank?
          # Ищем первый вес в разумном диапазоне для мебели (от 0.1 до 500 кг)
          page_text.scan(/([\d,\.]+)\s*(kg|кг)/i) do |match|
            weight_value = match[0].gsub(',', '.').to_f
            # Берем первый найденный вес в разумном диапазоне (это вес с упаковкой)
            if weight_value >= 0.1 && weight_value <= 500
              result[:weight] = weight_value.round(2)
              Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Found package weight (first match): #{result[:weight]} kg"
              break
            end
          end
        end
      end
      
      # Ищем размеры упаковки в тексте (если еще не найдены)
      if result[:package_dimensions].blank?
        # Ищем в секции упаковки
        packaging_sections = doc.css('*').select { |el| 
          text = el.text.downcase
          text.include?('opakowanie') || text.include?('paczk') || text.include?('упаковка') || text.include?('пакет')
        }
        
        packaging_sections.each do |section|
          section_text = section.text.downcase
          width = section_text.match(/(?:szerokość|ширина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
          height = section_text.match(/(?:wysokość|высота)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
          length = section_text.match(/(?:długość|длина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)&.captures&.first
          
          if width && height && length
            result[:package_dimensions] = "#{width.gsub(',', '.')} × #{height.gsub(',', '.')} × #{length.gsub(',', '.')} cm"
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Package dimensions from packaging section text: #{result[:package_dimensions]}"
            break
          end
        end
      end
      
      # Ищем размеры продукта в тексте (если еще не найдены)
      if result[:dimensions].blank?
        # Ищем в секции с размерами
        dimensions_sections = doc.css('*').select { |el| 
          text = el.text.downcase
          text.include?('wymiary') || text.include?('rozmiar') || text.include?('размеры') || text.include?('размер')
        }
        
        dimensions_sections.each do |section|
          section_text = section.text.downcase
          width_match = section_text.match(/(?:szerokość|ширина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          depth_match = section_text.match(/(?:głębokość|глубина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          height_match = section_text.match(/(?:wysokość|высота)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          
          if width_match && depth_match
            dims = [
              width_match[1].gsub(',', '.'),
              depth_match[1].gsub(',', '.'),
              height_match&.captures&.first&.gsub(',', '.')
            ].compact.reject(&:empty?)
            result[:dimensions] = dims.join(' × ') + ' cm' if dims.any?
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Dimensions from dimensions section: #{result[:dimensions]}"
            break
          end
        end
        
        # Если не нашли в секциях, ищем по всей странице
        if result[:dimensions].blank?
          width_match = page_text.downcase.match(/(?:szerokość|ширина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          depth_match = page_text.downcase.match(/(?:głębokość|глубина)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          height_match = page_text.downcase.match(/(?:wysokość|высота)[:\s]+([\d,\.]+)\s*(?:cm|см)/i)
          
          if width_match && depth_match
            dims = [
              width_match[1].gsub(',', '.'),
              depth_match[1].gsub(',', '.'),
              height_match&.captures&.first&.gsub(',', '.')
            ].compact.reject(&:empty?)
            result[:dimensions] = dims.join(' × ') + ' cm' if dims.any?
            Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Dimensions from page text: #{result[:dimensions]}"
          end
        end
      end
      
      # Если размеры не найдены, пробуем извлечь из JSON-LD (если еще не сделали)
      if result[:dimensions].blank?
        doc.css('script[type="application/ld+json"]').each do |script|
          begin
            schema_data = JSON.parse(script.text)
            if schema_data['@type'] == 'Product'
              width = schema_data['width']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
              height = schema_data['height']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
              depth = schema_data['depth']&.to_s&.gsub(/\s*cm\s*/i, '')&.gsub(',', '.')
              
              if width && depth
                # Если height не указан в JSON-LD, ищем его в тексте страницы
                if height.blank? || height.empty?
                  height_match = page_text.match(/wysokość[:\s]+([\d,\.]+)\s*cm/i)
                  height = height_match&.captures&.first&.gsub(',', '.') if height_match
                end
                
                dims = [width, depth, height].compact.reject(&:empty?)
                result[:dimensions] = dims.join(' × ') + ' cm' if dims.any?
                Rails.logger.debug "PlDetailsFetcher.extract_packaging_info: Dimensions from JSON-LD: #{result[:dimensions]}"
                break
              end
            end
          rescue JSON::ParserError
            next
          end
        end
      end
    end
    
    Rails.logger.info "PlDetailsFetcher.extract_packaging_info: Extracted - weight: #{result[:weight]}, net_weight: #{result[:net_weight]}, volume: #{result[:package_volume]}, dimensions: #{result[:dimensions]}, package_dimensions: #{result[:package_dimensions]}"
    result
  end
  
  def extract_videos(doc, product_data)
    videos = []
    
    # Из productData
    video_section = product_data&.dig('videoSection') || product_data&.dig('mediaSection')
    if video_section
      if video_section.is_a?(Array)
        videos.concat(video_section.map { |v| v['url'] || v['src'] }.compact)
      elsif video_section.is_a?(Hash)
        videos << video_section['url'] if video_section['url']
      end
    end
    
    # Из HTML
    doc.css('iframe[src*="youtube"], iframe[src*="vimeo"], video source').each do |el|
      src = el['src'] || el['data-src']
      videos << src if src.present?
    end
    
    videos.uniq.compact
  end
  
  def extract_manuals(doc, product_data)
    manuals = []
    
    # Из productData
    attachments = product_data&.dig('productInformationSection', 'attachments', 'manual')
    if attachments
      if attachments.is_a?(Array)
        manuals.concat(attachments.map { |m| m['url'] || m }.compact)
      else
        manuals << attachments['url'] if attachments['url']
      end
    end
    
    # Из HTML
    doc.css('a[href*="manual"], a[href*="instruction"], a[href*="assembly"]').each do |link|
      href = link['href']
      manuals << href if href.present?
    end

    manuals.compact.uniq { |m| self.class.canonical_document_url_for_dedupe(m.to_s) }
  end

  # Типы вариантов по видимым на странице пикерам (см. IkeaLvProductVariantsService).
  def infer_variant_picker_types_from_doc(doc)
    types = []
    types << "color" if doc.at_css(".pipf-product-style-picker__picker")
    if doc.at_css(".pipf-product-variation-section a[href*='/p/']")
      types << "size"
    end
    types.uniq.join(",")
  end

  # Полный снимок модалки «Подробная информация о товаре» (.pipf-product-details-modal):
  # плоские поля для merge + JSON в product.full_attributes[:product_details_modal].
  def extract_pipf_product_details_modal_complete(pip_modal)
    snapshot = {
      "title" => normalize_text(pip_modal.at_css(".pipf-product-details-modal__title, h2#pip-modal-header")&.text),
      "intro_paragraphs" => [],
      "identifiers" => [],
      "accordion_sections" => []
    }
    fields = {}

    pip_modal.children.each do |node|
      next unless node.element?

      cls = node["class"].to_s
      break if node.name == "ul" && cls.include?("pipf-accordion")

      next unless cls.include?("pipf-product-details-modal__container")

      node.css("p.pipf-product-details-modal__paragraph").each do |p|
        t = normalize_text(p.text)
        snapshot["intro_paragraphs"] << t if t.present?
      end
    end

    if snapshot["intro_paragraphs"].any?
      fields[:short_description] = snapshot["intro_paragraphs"].first
      fields[:description] = snapshot["intro_paragraphs"].join("\n\n")
    end

    pip_modal.css(".pipf-product-identifier").each do |ident|
      label = normalize_text(ident.at_css(".pipf-product-identifier__label")&.text)
      value = normalize_text(ident.at_css(".pipf-product-identifier__value")&.text)
      row = { "label" => label, "value" => value }.compact
      snapshot["identifiers"] << row if row.any?
    end

    accordion = pip_modal.at_css("ul.pipf-accordion")
    if accordion
      accordion.children.each do |item|
        next unless item.element? && item.name == "li"

        section_snap = snapshot_pipf_accordion_section(item)
        snapshot["accordion_sections"] << section_snap if section_snap.present?

        id = item["id"].to_s
        if id.include?("good-to-know")
          txt = pipf_accordion_section_plain_text(item)
          fields[:good_to_know] = txt if txt.present?
          env_lines = txt.to_s.split("\n\n").select do |ln|
            ln.match?(/переработ|recycl|эколог|отходов|IKEA of Sweden/i)
          end
          fields[:environmental_info] = env_lines.join("\n\n") if env_lines.any?
        elsif id.include?("material-and-care")
          fields[:materials] = extract_materials_text_from_pipf_modal_li(item)
          fields[:care_instructions] = extract_care_text_from_pipf_modal_li(item)
        elsif id.include?("safety")
          fields[:safety_info] = pipf_accordion_section_plain_text(item)
        elsif id.include?("assembly") || id.include?("documents")
          docs = extract_pipf_modal_document_links(item)
          fields[:assembly_documents] = docs if docs.any?
        end
      end
    end

    { fields: fields, snapshot: snapshot }
  end

  def snapshot_pipf_accordion_section(li)
    title = normalize_text(li.at_css(".pipf-accordion-item-header__title, span[id$='_title']")&.text)
    content = li.at_css(".pipf-accordion__content") || li
    sec = {
      "id" => li["id"].presence,
      "title" => title.presence,
      "paragraphs" => [],
      "material_blocks" => [],
      "care_blocks" => [],
      "document_groups" => []
    }

    content.css(".pipf-product-details-modal__paragraph, span.pipf-product-details-modal__paragraph").each do |n|
      t = normalize_text(n.text)
      sec["paragraphs"] << t if t.present?
    end
    sec["paragraphs"].uniq!

    content.css(".pipf-product-details-modal__container").each do |cont|
      sub = normalize_text(cont.at_css(".pipf-product-details-modal__material-sub-header")&.text)
      pairs = []
      cont.css("dl.pipf-product-details-modal__section dt").each do |dt|
        dd = find_next_dd(dt)
        next unless dd

        pairs << {
          "term" => normalize_text(dt.text),
          "definition" => normalize_text(dd.text)
        }
      end
      next if sub.blank? && pairs.empty?

      sec["material_blocks"] << { "subheader" => sub.presence, "pairs" => pairs }
    end

    care_h = content.at_css("h4.pipf-product-details-modal__care-header")
    if care_h
      lines = pipf_collect_care_lines_after_header(li, care_h)
      sec["care_blocks"] << { "lines" => lines } if lines.any?
    end

    content.css(".pipf-product-details-modal__container").each do |cont|
      hdr = cont.at_css("h4.pipf-product-details-modal__document-header")
      next unless hdr

      header_txt = normalize_text(hdr.text)
      links = cont.css("a.pipf-product-details-modal__document-link, a[href*='/pdoc/']").filter_map do |a|
        href = a["href"].to_s.strip
        next if href.blank?

        title = normalize_text(a.css("span").map(&:text).join(" ").strip)
        if title.blank?
          title = normalize_text(a.text).gsub(/\d{3}\.\d{3}\.\d{2}/, "").strip
        end
        { "title" => title.presence || "Document", "url" => href }
      end.uniq { |x| canonical_document_url_for_dedupe(x["url"]) }

      sec["document_groups"] << { "header" => header_txt, "links" => links } if links.any?
    end

    sec.compact.reject { |_, v| v.blank? || (v.is_a?(Array) && v.empty?) }
  end

  def pipf_accordion_section_plain_text(li)
    li.css(".pipf-accordion__content .pipf-product-details-modal__paragraph, .pipf-accordion__content p, .pipf-accordion__content span.pipf-product-details-modal__paragraph")
      .map { |n| normalize_text(n.text) }.compact.reject(&:blank?).uniq.join("\n\n").presence
  end

  def extract_materials_text_from_pipf_modal_li(li)
    lines = []
    li.css("dl.pipf-product-details-modal__section dt").each do |dt|
      dd = find_next_dd(dt)
      next unless dd

      lines << "#{normalize_text(dt.text)}: #{normalize_text(dd.text)}"
    end
    lines.uniq.join("\n").presence
  end

  def pipf_collect_care_lines_after_header(li, care_h)
    parts = []
    after = false
    li.traverse do |node|
      next unless node.element?

      if node == care_h
        after = true
        next
      end
      next unless after

      c = node["class"].to_s
      if c.include?("pipf-product-details-modal__label")
        parts << normalize_text(node.text)
      elsif c.include?("pipf-product-details-modal__header") &&
            !c.include?("material-header") &&
            !c.include?("document-header")
        t = normalize_text(node.text)
        parts << t if t.length > 2
      end
    end
    parts.uniq
  end

  def extract_care_text_from_pipf_modal_li(li)
    care_h = li.at_css("h4.pipf-product-details-modal__care-header")
    return nil unless care_h

    pipf_collect_care_lines_after_header(li, care_h).join("\n").presence
  end

  def extract_pipf_modal_document_links(li)
    li.css("a.pipf-product-details-modal__document-link, a[href*='/pdoc/']").filter_map do |a|
      href = a["href"].to_s.strip
      next if href.blank?

      title = normalize_text(a.css("span").map(&:text).join(" ").strip)
      if title.blank?
        title = normalize_text(a.text).gsub(/\d{3}\.\d{3}\.\d{2}/, "").strip
      end
      { url: href, title: title.presence || "Document" }
    end.uniq { |x| self.class.canonical_document_url_for_dedupe(x[:url]) }
  end

  def pipf_product_details_props(product_data)
    return nil unless product_data.is_a?(Hash)

    product_data.dig("pageProps", "productInformationSectionProps", "productDetailsProps")
  end

  def pipf_measurements_props(product_data)
    return nil unless product_data.is_a?(Hash)

    product_data.dig("pageProps", "productInformationSectionProps", "measurementsProps")
  end

  def extract_pipf_measurements_modal_combined(doc, product_data)
    hyd = extract_measurements_modal_from_hydration_measurements_props(pipf_measurements_props(product_data))
    dom = extract_measurements_modal_from_dom(doc)
    merge_measurements_modal_dom_and_hydration(dom, hyd)
  end

  def merge_measurements_modal_dom_and_hydration(dom, hyd)
    d_snap = dom[:snapshot].is_a?(Hash) ? dom[:snapshot] : {}
    h_snap = hyd[:snapshot].is_a?(Hash) ? hyd[:snapshot] : {}
    merged_snap = h_snap.stringify_keys.merge(d_snap.stringify_keys)
    merged_snap["product_measurements"] =
      if d_snap["product_measurements"].is_a?(Array) && d_snap["product_measurements"].any?
        d_snap["product_measurements"]
      else
        h_snap["product_measurements"] || []
      end
    merged_snap["packages"] =
      if d_snap["packages"].is_a?(Array) && d_snap["packages"].any?
        d_snap["packages"]
      elsif h_snap["packages"].is_a?(Array) && h_snap["packages"].any?
        h_snap["packages"]
      end
    merged_snap["number_of_packages"] ||= d_snap["number_of_packages"] || h_snap["number_of_packages"]
    merged_snap["packaging_title"] ||= d_snap["packaging_title"] || h_snap["packaging_title"]
    merged_snap["diagram_image"] =
      d_snap["diagram_image"].presence ||
      h_snap["diagram_image"].presence ||
      measurement_diagram_image_from_props_images(h_snap["images"])
    merged_snap["images"] ||= h_snap["images"] if h_snap["images"].present?
    merged_snap["fallback_image"] ||= h_snap["fallback_image"] if h_snap["fallback_image"].present?
    merged_snap["title"] = d_snap["title"].presence || h_snap["title"].presence || merged_snap["title"]
    sources = [h_snap["source"], d_snap["source"]].compact.reject(&:blank?).uniq
    merged_snap["source"] = sources.join("+") if sources.any?

    d_fields = dom[:fields].is_a?(Hash) ? dom[:fields] : {}
    h_fields = hyd[:fields].is_a?(Hash) ? hyd[:fields] : {}
    merged_fields = h_fields.merge(d_fields) { |_k, h, d| d.present? ? d : h }

    { fields: merged_fields, snapshot: merged_snap.compact }
  end

  def extract_measurements_modal_from_hydration_measurements_props(props)
    return { fields: {}, snapshot: {} } if props.blank?

    fields = measurement_fields_from_measurements_props(props)
    snapshot = measurements_modal_snapshot_from_hydration_props(props)
    { fields: fields, snapshot: snapshot }
  end

  def measurements_modal_snapshot_from_hydration_props(props)
    pk = props.dig("packaging", "contentProps", "packages")
    diagram = measurement_diagram_image_from_props_images(props["images"])
    {
      "title" => normalize_text(props["title"]).presence,
      "choose_different_size_link_text" => props["chooseDifferentSizeLinkText"],
      "event_label" => props["eventLabel"],
      "fallback_image" => props["fallbackImage"],
      "images" => props["images"],
      "diagram_image" => diagram,
      "product_measurements" => props["measurements"],
      "number_of_packages" => props.dig("packaging", "contentProps", "numberOfPackages"),
      "packaging_title" => props.dig("packaging", "title"),
      "packages" => pk,
      "source" => "hydration_measurementsProps"
    }.compact
  end

  def measurement_diagram_image_from_props_images(images)
    arr = Array(images)
    img = arr.find { |im| im.is_a?(Hash) && im["type"].to_s == "MEASUREMENT_ILLUSTRATION" } || arr.first
    return nil unless img.is_a?(Hash) && img["url"].present?

    { "url" => img["url"].to_s.split("?").first, "alt" => img["alt"].to_s.strip.presence, "type" => img["type"] }.compact
  end

  def measurement_fields_from_measurements_props(props)
    fields = {}
    dims = product_dimensions_wdh_from_measurement_rows(Array(props["measurements"]))
    fields[:dimensions] = dims if dims.present?

    pk = props.dig("packaging", "contentProps", "packages")
    wsum = total_weight_kg_from_measurement_packages(pk)
    fields[:weight] = wsum if wsum.present? && wsum.positive?

    pdim, vol = primary_package_dimensions_and_volume_sum(pk)
    fields[:package_dimensions] = pdim if pdim.present?
    fields[:package_volume] = vol if vol.present? && vol.positive?

    fields
  end

  def product_dimensions_wdh_from_measurement_rows(rows)
    map = { width: nil, depth: nil, height: nil }
    rows.each do |row|
      next unless row.is_a?(Hash)

      role = measurement_axis_role_from_label(row["name"])
      next unless role

      num = parse_measurement_cm_scalar(row["measure"] || row["text"])
      next unless num

      map[role] ||= num
    end
    return nil unless map[:width] && map[:depth] && map[:height]

    "#{map[:width]} × #{map[:depth]} × #{map[:height]} cm"
  end

  # Только базовые три габарита товара (первая строка «Ширина» / «Глубина» / «Высота» в модалке),
  # без «ширина кровати», «глубина сиденья» и т.п.
  def measurement_axis_role_from_label(label)
    s = label.to_s.strip.downcase.gsub(/\u00a0/, " ")
    return :width if s.match?(/\Aширина\z|szerokość\z|szerokosc\z|breite\z|\Awidth\z/i)
    return :depth if s.match?(/\Aглубина\z|głębokość\z|glebokosc\z|głęb\z|tiefe\z|\Adepth\z/i)
    return :height if s.match?(/\Aвысота\z|wysokość\z|wysokosc\z|höhe\z|\Aheight\z/i)

    nil
  end

  def parse_measurement_cm_scalar(text)
    return nil if text.blank?

    m = text.to_s.match(/([\d]+[.,]?\d*)\s*(?:cm|см)?/i)
    return nil unless m

    m[1].tr(",", ".").to_f
  end

  def total_weight_kg_from_measurement_packages(packages)
    total = 0.0
    Array(packages).each do |pkg|
      next unless pkg.is_a?(Hash)

      w = nil
      Array(pkg["measurements"]).each do |grp|
        Array(grp).each do |item|
          next unless item.is_a?(Hash)

          next unless item["type"].to_s == "weight" && item["value"].present?

          w = item["value"].to_f
        end
      end
      next unless w

      qty = pkg.dig("quantity", "value")
      q = qty.present? ? qty.to_i : 1
      q = 1 if q < 1
      total += w * q
    end
    total.round(2) if total.positive?
  end

  def primary_package_dimensions_and_volume_sum(packages)
    primary_lwh = nil
    vol_sum = 0.0

    Array(packages).each do |pkg|
      next unless pkg.is_a?(Hash)

      lwh = { w: nil, h: nil, l: nil }
      Array(pkg["measurements"]).each do |grp|
        Array(grp).each do |item|
          next unless item.is_a?(Hash)

          case item["type"].to_s
          when "width"
            lwh[:w] = item["value"].presence&.to_f || parse_measurement_cm_scalar(item["text"])
          when "height"
            lwh[:h] = item["value"].presence&.to_f || parse_measurement_cm_scalar(item["text"])
          when "length", "depth"
            lwh[:l] = item["value"].presence&.to_f || parse_measurement_cm_scalar(item["text"])
          end
        end
      end
      if lwh[:w] && lwh[:h] && lwh[:l]
        vol_sum += (lwh[:w] * lwh[:h] * lwh[:l]) / 1000.0
        primary_lwh ||= "#{lwh[:w]} × #{lwh[:h]} × #{lwh[:l]} cm"
      end
    end

    vol_round = vol_sum.round(3)
    vol_final = vol_round.positive? ? vol_round : nil
    [primary_lwh, vol_final]
  end

  def extract_measurements_modal_from_dom(doc)
    modal = doc.at_css(".pipf-measurements-modal")
    return { fields: {}, snapshot: {} } unless modal

    snapshot = {
      "title" => normalize_text(modal.at_css(".pipf-measurements-modal__title, h2#pip-modal-header")&.text).presence,
      "product_measurements" => [],
      "packages" => [],
      "source" => "dom_pipf_measurements_modal"
    }

    modal.css(".pipf-measurements-modal__product-measurement-wrapper").each do |li|
      name_el = li.at_css(".pipf-measurements-modal__product-measurement-name")
      name = normalize_text(name_el&.text).gsub(":", "").strip
      rest = li.xpath("./text()").map(&:text).join
      value = normalize_text(rest)
      snapshot["product_measurements"] << { "name" => name, "measure" => value } if name.present? || value.present?
    end

    img = modal.at_css(".pipf-measurements-modal__image-container img")
    if img && (img["src"].present? || img["data-src"].present?)
      snapshot["diagram_image"] = {
        "url" => (img["src"].presence || img["data-src"]).to_s.split("?").first,
        "alt" => img["alt"].to_s.strip.presence
      }.compact
    end

    pkg_note = modal.at_css(".pipf-measurements-modal__package-count")
    snapshot["package_count_note"] = normalize_text(pkg_note.text) if pkg_note

    modal.css(".pipf-measurements-modal__package-container").each do |pc|
      pkg = extract_dom_measurement_package_block(pc)
      snapshot["packages"] << pkg if pkg.present?
    end

    snapshot["number_of_packages"] = snapshot["packages"].size if snapshot["packages"].any?

    packaging_li = modal.at_css("li#measurements-packaging, li[id*='measurements-packaging']")
    if packaging_li
      t = packaging_li.at_css(".pipf-accordion-item-header__title, span[id$='_title']")&.text
      snapshot["packaging_title"] = normalize_text(t) if t.present?
    end

    fields = measurement_fields_from_dom_snapshot(snapshot)
    { fields: fields, snapshot: snapshot.compact }
  end

  def extract_dom_measurement_package_block(pc)
    name = normalize_text(pc.at_css("h4.pipf-measurements-modal__package-header")&.text)
    type_name = normalize_text(pc.at_css('span[aria-hidden="true"]')&.text)
    ident = pc.at_css(".pipf-product-identifier")
    label = normalize_text(ident.at_css(".pipf-product-identifier__label")&.text)
    value = normalize_text(ident.at_css(".pipf-product-identifier__value")&.text)

    measurements = []
    pc.css(".pipf-measurements-modal__package-measurement-wrapper").each do |li|
      n = normalize_text(li.at_css(".pipf-measurements-modal__package-measurement-name")&.text).gsub(":", "").strip
      rest = li.xpath("./text()").map(&:text).join
      v = normalize_text(rest)
      val_span = li.at_css(".pipf-measurements-modal__package-measurement-value")
      v = normalize_text(val_span.text) if v.blank? && val_span
      measurements << { "name" => n, "measure" => v } if n.present? || v.present?
    end

    return nil if name.blank? && type_name.blank? && measurements.empty?

    {
      "name" => name.presence,
      "type_name" => type_name.presence,
      "article_number" => ({ "label" => label, "value" => value }.compact.presence),
      "measurements" => measurements
    }.compact
  end

  def measurement_fields_from_dom_snapshot(snapshot)
    fields = {}
    rows = Array(snapshot["product_measurements"])
    dims = product_dimensions_wdh_from_dom_measurement_rows(rows)
    fields[:dimensions] = dims if dims.present?

    pk = Array(snapshot["packages"])
    wsum = total_weight_kg_from_dom_packages(pk)
    fields[:weight] = wsum if wsum.present? && wsum.positive?

    pdim, vol = primary_package_dimensions_and_volume_from_dom(pk)
    fields[:package_dimensions] = pdim if pdim.present?
    fields[:package_volume] = vol if vol.present? && vol.positive?

    fields
  end

  def product_dimensions_wdh_from_dom_measurement_rows(rows)
    map = { width: nil, depth: nil, height: nil }
    rows.each do |row|
      next unless row.is_a?(Hash)

      role = measurement_axis_role_from_label(row["name"])
      next unless role

      num = parse_measurement_cm_scalar(row["measure"])
      next unless num

      map[role] ||= num
    end
    return nil unless map[:width] && map[:depth] && map[:height]

    "#{map[:width]} × #{map[:depth]} × #{map[:height]} cm"
  end

  def total_weight_kg_from_dom_packages(packages)
    total = 0.0
    packages.each do |pkg|
      next unless pkg.is_a?(Hash)

      Array(pkg["measurements"]).each do |m|
        next unless m.is_a?(Hash)

        name = m["name"].to_s.downcase
        next unless name.match?(/вес|weight|waga/)

        str = m["measure"].to_s
        mm = str.match(/([\d]+[.,]?\d*)\s*(kg|кг)/i)
        next unless mm

        total += mm[1].tr(",", ".").to_f
      end
    end
    total.round(2) if total.positive?
  end

  def primary_package_dimensions_and_volume_from_dom(packages)
    primary_lwh = nil
    vol_sum = 0.0

    packages.each do |pkg|
      next unless pkg.is_a?(Hash)

      w = h = l = nil
      Array(pkg["measurements"]).each do |m|
        next unless m.is_a?(Hash)

        name = m["name"].to_s.downcase
        val = parse_measurement_cm_scalar(m["measure"])
        next unless val

        if name.match?(/ширина|szerokość|szerokosc|width/)
          w = val
        elsif name.match?(/высота|wysokość|wysokosc|height/)
          h = val
        elsif name.match?(/длина|długość|dlugosc|length/)
          l = val
        end
      end
      next unless w && h && l

      vol_sum += (w * h * l) / 1000.0
      primary_lwh ||= "#{w} × #{h} × #{l} cm"
    end

    vol_round = vol_sum.round(3)
    [primary_lwh, vol_round.positive? ? vol_round : nil]
  end

  # Данные модалки «Подробная информация» часто только в hydration (accordionObject), без ul.pipf-accordion в HTML.
  def extract_pipf_modal_from_hydration_product_details_props(props)
    return { fields: {}, snapshot: {} } if props.blank?

    fields = {}
    snapshot = {
      "title" => props["title"],
      "intro_paragraphs" => [],
      "identifiers" => [],
      "accordion_sections" => [],
      "source" => "hydration_productDetailsProps"
    }

    pd = props["productDescriptionProps"]
    if pd.is_a?(Hash)
      paras = Array(pd["paragraphs"]).map { |t| normalize_text(t) }.reject(&:blank?)
      snapshot["intro_paragraphs"] = paras
      if paras.any?
        fields[:short_description] = paras.first
        fields[:description] = paras.join("\n\n")
      end
      dname = normalize_text(pd["designerName"])
      fields[:designer] = dname if dname.present?
    end

    label = props["articleNumberLabel"].to_s.strip
    pid = props["productId"].to_s.gsub(/\D/, "")
    if pid.match?(/\A\d{8}\z/)
      formatted = "#{pid[0, 3]}.#{pid[3, 3]}.#{pid[6, 2]}"
      row = { "label" => label.presence, "value" => formatted }.compact
      snapshot["identifiers"] << row if row.any?
    end

    acc = props["accordionObject"]
    if acc.is_a?(Hash)
      acc.each_value do |section|
        next unless section.is_a?(Hash)

        sec_snap = snapshot_accordion_section_from_hydration(section)
        snapshot["accordion_sections"] << sec_snap if sec_snap.present?

        sid = section["id"].to_s
        cp = section["contentProps"]
        next unless cp.is_a?(Hash)

        if sid.include?("good-to-know")
          txt = hydration_good_to_know_plain_text(cp)
          fields[:good_to_know] = txt if txt.present?
          env_lines = txt.to_s.split("\n\n").select do |ln|
            ln.match?(/переработ|recycl|эколог|отходов|IKEA of Sweden/i)
          end
          fields[:environmental_info] = env_lines.join("\n\n") if env_lines.any?
        elsif sid.include?("material-and-care")
          fields[:materials] = materials_from_hydration_materials_and_care(cp)
          fields[:care_instructions] = care_from_hydration_materials_and_care(cp)
        elsif sid.include?("safety")
          fields[:safety_info] = safety_from_hydration_safety_block(cp)
        elsif sid.include?("assembly") || sid.include?("documents")
          docs = assembly_documents_from_hydration_attachments(cp)
          fields[:assembly_documents] = docs if docs.any?
        end
      end
    end

    { fields: fields, snapshot: snapshot }
  end

  def hydration_good_to_know_plain_text(cp)
    Array(cp["goodToKnow"]).filter_map do |x|
      next unless x.is_a?(Hash)

      normalize_text(x["text"])
    end.reject(&:blank?).join("\n\n").presence
  end

  def materials_from_hydration_materials_and_care(cp)
    lines = []
    Array(cp["materials"]).each do |block|
      next unless block.is_a?(Hash)

      pt = normalize_text(block["productType"])
      lines << pt if pt.present?
      Array(block["materials"]).each do |m|
        next unless m.is_a?(Hash)

        part = normalize_text(m["part"])
        mat = normalize_text(m["material"])
        lines << "#{part} #{mat}".strip if part.present? && mat.present?
      end
    end
    lines.uniq.join("\n").presence
  end

  def care_from_hydration_materials_and_care(cp)
    parts = []
    Array(cp["careInstructions"]).each do |ci|
      next unless ci.is_a?(Hash)

      h = normalize_text(ci["header"])
      pt = normalize_text(ci["productType"])
      parts << h if h.present?
      parts << pt if pt.present? && pt != h
      Array(ci["texts"]).each { |t| parts << normalize_text(t) }
    end
    parts.reject(&:blank?).uniq.join("\n").presence
  end

  def safety_from_hydration_safety_block(cp)
    Array(cp["safetyAndCompliance"]).filter_map do |x|
      next unless x.is_a?(Hash)

      normalize_text(x["text"])
    end.reject(&:blank?).uniq.join("\n\n").presence
  end

  def assembly_documents_from_hydration_attachments(cp)
    att = cp["attachments"]
    return [] unless att.is_a?(Hash)

    out = []
    att.each_value do |grp|
      next unless grp.is_a?(Hash)

      Array(grp["attachments"]).each do |a|
        next unless a.is_a?(Hash)

        url = a["url"].to_s.strip
        next if url.blank?

        title = normalize_text(a["label"])
        out << { url: url, title: title.presence || "Document" }
      end
    end
    out.uniq { |x| self.class.canonical_document_url_for_dedupe(x[:url]) }
  end

  def snapshot_accordion_section_from_hydration(section)
    id = section["id"].to_s
    title = normalize_text(section["title"])
    cp = section["contentProps"]
    return nil if cp.blank?

    out = {
      "id" => id.presence,
      "title" => title.presence,
      "paragraphs" => [],
      "material_blocks" => [],
      "care_blocks" => [],
      "document_groups" => []
    }

    if id.include?("good-to-know")
      Array(cp["goodToKnow"]).each do |x|
        next unless x.is_a?(Hash)

        t = normalize_text(x["text"])
        out["paragraphs"] << t if t.present?
      end
    elsif id.include?("material-and-care")
      Array(cp["materials"]).each do |block|
        next unless block.is_a?(Hash)

        sub = normalize_text(block["productType"])
        pairs = Array(block["materials"]).filter_map do |m|
          next unless m.is_a?(Hash)

          part = normalize_text(m["part"])
          mat = normalize_text(m["material"])
          next if part.blank? && mat.blank?

          { "term" => part, "definition" => mat }
        end
        out["material_blocks"] << { "subheader" => sub.presence, "pairs" => pairs } if sub.present? || pairs.any?
      end
      Array(cp["careInstructions"]).each do |ci|
        next unless ci.is_a?(Hash)

        lines = Array(ci["texts"]).map { |t| normalize_text(t) }.reject(&:blank?)
        out["care_blocks"] << {
          "header" => normalize_text(ci["header"]),
          "product_type" => normalize_text(ci["productType"]),
          "lines" => lines
        }.compact if lines.any? || ci["header"].present?
      end
    elsif id.include?("safety")
      Array(cp["safetyAndCompliance"]).each do |x|
        next unless x.is_a?(Hash)

        t = normalize_text(x["text"])
        out["paragraphs"] << t if t.present?
      end
    elsif id.include?("assembly") || id.include?("documents")
      att = cp["attachments"]
      if att.is_a?(Hash)
        att.each_value do |grp|
          next unless grp.is_a?(Hash)

          hdr = normalize_text(grp["header"])
          links = Array(grp["attachments"]).filter_map do |a|
            next unless a.is_a?(Hash)

            url = a["url"].to_s.strip
            next if url.blank?

            { "title" => normalize_text(a["label"]).presence || "Document", "url" => url }
          end.uniq { |z| z["url"] }
          out["document_groups"] << { "header" => hdr, "links" => links } if links.any?
        end
      end
    end

    out["paragraphs"].uniq!
    out.compact.reject { |_, v| v.blank? || (v.is_a?(Array) && v.empty?) }
  end

  def merge_pipf_modal_dom_and_hydration(dom, hyd)
    d_snap = dom[:snapshot].is_a?(Hash) ? dom[:snapshot] : {}
    h_snap = hyd[:snapshot].is_a?(Hash) ? hyd[:snapshot] : {}
    merged_snap = h_snap.stringify_keys.merge(d_snap.stringify_keys)
    merged_snap["intro_paragraphs"] = d_snap["intro_paragraphs"].presence || h_snap["intro_paragraphs"] || []
    merged_snap["identifiers"] = d_snap["identifiers"].presence || h_snap["identifiers"] || []
    merged_snap["accordion_sections"] = d_snap["accordion_sections"].presence || h_snap["accordion_sections"] || []
    merged_snap["title"] = d_snap["title"].presence || h_snap["title"]

    sources = [h_snap["source"], d_snap["source"]].compact.reject(&:blank?).uniq
    merged_snap["source"] = sources.join("+") if sources.any?

    d_fields = dom[:fields].is_a?(Hash) ? dom[:fields] : {}
    h_fields = hyd[:fields].is_a?(Hash) ? hyd[:fields] : {}
    merged_fields = h_fields.merge(d_fields) { |_k, h, d| d.present? ? d : h }

    { fields: merged_fields, snapshot: merged_snap }
  end

  # Извлечение данных из модального окна с описанием продукта
  # Гибкий метод, который работает даже если модальное окно загружается через JS
  def extract_modal_details(doc, product_data = nil)
    result = {}
    
    Rails.logger.debug "PlDetailsFetcher.extract_modal_details: Starting extraction"
    
    # Ищем модальное окно по разным селекторам (может быть скрыто или в HTML)
    modal_selectors = [
      '.pipf-product-details-modal',
      '[class*="product-details-modal"]',
      '[id*="product-details"]',
      '[aria-labelledby*="pip-modal-header"]',
      '[aria-modal="true"]',
      '.pipf-sheets',
      '[role="dialog"]'
    ]
    
    modal = nil
    modal_selectors.each do |selector|
      modal = doc.css(selector).first
      break if modal
    end
    
    # Если модальное окно не найдено, извлекаем данные напрямую из секций страницы.
    # На новых страницах IKEA (PIPF) модальный контейнер (sheet/dialog) создаётся
    # только после клика, но контент разделов часто уже присутствует в HTML
    # (как обычные заголовки + блоки текста).
    if modal.nil?
      Rails.logger.debug "PlDetailsFetcher.extract_modal_details: Modal not found in HTML, trying section-based extraction"
      extract_from_pipf_sections(doc, result)

      # Дополнительно пробуем найти данные в скриптах (если HTML совсем пустой)
      extract_from_scripts(doc, result) if result.blank?

      modal = doc # используем весь документ как область поиска для legacy методов
    else
      Rails.logger.debug "PlDetailsFetcher.extract_modal_details: Found product details modal"
    end

    pip_modal = doc.at_css(".pipf-product-details-modal")
    dom_complete = pip_modal ? extract_pipf_product_details_modal_complete(pip_modal) : { fields: {}, snapshot: {} }
    props = pipf_product_details_props(product_data)
    hyd_complete = extract_pipf_modal_from_hydration_product_details_props(props)
    complete = merge_pipf_modal_dom_and_hydration(dom_complete, hyd_complete)
    complete[:fields].each do |key, val|
      next if val.blank?

      result[key] = val
    end
    if complete[:snapshot].present?
      result[:product_details_modal] = complete[:snapshot]
      intro_n = complete[:snapshot]["intro_paragraphs"]&.size
      sec_n = complete[:snapshot]["accordion_sections"]&.size
      Rails.logger.info "PlDetailsFetcher.extract_modal_details: pipf modal merged intro=#{intro_n} accordion_sections=#{sec_n}"
    end

    # Дозаполняем поля, если полный разбор модалки не сработал или дал пробелы
    extract_description_from_modal(modal, result) if result[:description].blank?
    extract_designer_from_modal(modal, doc, result) if result[:designer].blank?
    if result[:materials].blank? || result[:care_instructions].blank?
      extract_materials_and_care_from_modal(modal, doc, result)
    end
    extract_safety_info_from_modal(modal, result) if result[:safety_info].blank?
    extract_good_to_know_from_modal(modal, result) if result[:good_to_know].blank?
    extract_documents_from_modal(modal, doc, result) if result[:assembly_documents].blank?
    
    Rails.logger.info "PlDetailsFetcher.extract_modal_details: Extracted - description: #{result[:description].present?}, materials: #{result[:materials].present?}, designer: #{result[:designer].present?}, documents: #{result[:assembly_documents]&.length || 0}"
    result
  end

  # --- PIPF section-based extraction (no click / no modal DOM) ---
  #
  # IKEA постепенно переводит страницы PIP на новую разметку (PIPF). В ней
  # "модальные" листы (sheets) появляются только после клика, но данные часто
  # уже присутствуют на странице в виде секций с заголовками.
  #
  # Этот метод пытается извлечь ключевые расширенные атрибуты, опираясь
  # на заголовки секций (PL/RU) и типичную структуру списков/таблиц.
  def extract_from_pipf_sections(doc, result)
    # 1) Informacje o produkcie / Информация о продукте
    info_section = find_section_by_heading(doc, [
      'Informacje o produkcie',
      'Информация о продукте'
    ])
    if info_section
      paragraphs = extract_text_blocks(info_section, prefer: %w[p]).select { |t| t.length > 20 }
      if paragraphs.any?
        result[:short_description] ||= paragraphs.first
        result[:description] ||= paragraphs.join("\n\n")
      end
    end

    # 2) Materiały i pielęgnacja (materials + care)
    mcare_section = find_section_by_heading(doc, [
      'Materiały i pielęgnacja',
      'Materiał i pielęgnacja',
      'Материалы и уход'
    ])
    if mcare_section
      materials_lines = extract_dt_dd_lines(mcare_section)
      if materials_lines.any?
        result[:materials] ||= materials_lines.join("\n")
      end

      care_lines = extract_list_lines(mcare_section).reject { |t| t.include?(':') }
      # фильтр: инструкции по уходу часто короткие (1-2 предложения) и без двоеточий
      care_lines = care_lines.select { |t| t.length.between?(3, 220) }
      if care_lines.any?
        result[:care_instructions] ||= care_lines.uniq.join("\n")
      end
    end

    # 3) Bezpieczeństwo / Safety
    safety_section = find_section_by_heading(doc, [
      'Bezpieczeństwo',
      'Bezpieczeństwo i zgodność',
      'Informacje o bezpieczeństwie',
      'Информация о безопасности',
      'Безопасность'
    ])
    if safety_section
      safety_lines = extract_list_lines(safety_section).select { |t| t.length > 10 }
      result[:safety_info] ||= safety_lines.uniq.join("\n") if safety_lines.any?
    end

    # 4) Dobrze wiedzieć / Good to know
    good_section = find_section_by_heading(doc, [
      'Dobrze wiedzieć',
      'Warto wiedzieć',
      'Полезно знать'
    ])
    if good_section
      good_lines = extract_list_lines(good_section).select { |t| t.length > 10 }
      result[:good_to_know] ||= good_lines.uniq.join("\n") if good_lines.any?
    end

    # 5) Dokumenty (assembly / manuals) - вытащим ссылки
    docs_section = find_section_by_heading(doc, [
      'Instrukcja montażu',
      'Instrukcje montażu',
      'Instrukcje i dokumenty',
      'Dokumenty',
      'Документы',
      'Инструкции'
    ])
    if docs_section
      links = docs_section.css('a').map do |a|
        href = a['href'].to_s.strip
        next if href.blank?
        href = "https://www.ikea.com#{href}" if href.start_with?('/')
        next unless href.match?(/assembly_instructions|manuals|product-support|documents/i)
        title = a.text.to_s.strip
        { title: title.presence || 'Document', url: href }
      end.compact

      if links.any?
        # Keep the same structure as extract_documents_from_modal: Array of {title, url}
        result[:assembly_documents] ||= links.uniq { |x| self.class.canonical_document_url_for_dedupe(x[:url]) }
      end
    end
  rescue => e
    Rails.logger.warn "PlDetailsFetcher.extract_from_pipf_sections: Failed: #{e.class} - #{e.message}"
  end

  def find_section_by_heading(doc, headings)
    normalized_targets = headings.compact.map { |h| normalize_text(h).downcase }
    return nil if normalized_targets.empty?

    candidates = doc.css('h1, h2, h3, [role="heading"]').to_a
    heading_node = candidates.find do |n|
      t = normalize_text(n.text)
      next false if t.blank?
      normalized_targets.include?(t.downcase)
    end

    return nil unless heading_node

    # На новых PIPF страницах заголовок часто лежит глубоко внутри "accordion item".
    # Поднимаемся до ближайшего контейнера, который вероятнее всего содержит контент.
    container = heading_node.ancestors.find do |a|
      cls = a['class'].to_s
      id = a['id'].to_s
      a.name == 'section' ||
        cls.include?('pipf-accordion') ||
        cls.include?('pipf-product-details') ||
        cls.include?('pip-product-details') ||
        id.include?('pip')
    end

    container || heading_node.parent
  end

  def extract_text_blocks(container, prefer: %w[p li dt dd])
    nodes = []
    prefer.each do |tag|
      nodes.concat(container.css(tag))
    end

    texts = nodes.map { |n| normalize_text(n.text) }
                 .reject(&:blank?)
                 .reject { |t| t.length < 2 }

    # remove duplicates preserving order
    seen = {}
    texts.select { |t| (seen[t] ||= false) == false && (seen[t] = true) }
  end

  def extract_list_lines(container)
    extract_text_blocks(container, prefer: %w[li p]).reject do |t|
      t.match?(/cookie|privacy|terms|regulamin|polityka/i)
    end
  end

  def extract_dt_dd_lines(container)
    lines = []
    container.css('dt').each do |dt|
      key = normalize_text(dt.text)
      next if key.blank?
      dd = find_next_dd(dt)
      val = dd ? normalize_text(dd.text) : nil
      next if val.blank?
      lines << "#{key}: #{val}"
    end
    lines.uniq
  end

  def normalize_text(text)
    text.to_s.gsub(/\u00A0/, ' ').gsub(/\s+/, ' ').strip
  end
  
  # Вспомогательные методы для извлечения данных из модального окна
  
  def extract_description_from_modal(modal, result)
    # Ищем все параграфы описания в модальном окне
    paragraphs = modal.css('.pipf-product-details-modal__paragraph').map(&:text).map(&:strip).compact.reject(&:empty?)
    
    # Фильтруем параграфы, которые похожи на описание продукта (не служебные)
    description_paragraphs = paragraphs.select { |p| 
      p.length > 30 && 
      !p.match?(/cookie|privacy|terms|regulamin|polityka|ikea\.com/i) &&
      !p.match?(/^\d+$/) # Не числа
    }
    
    if description_paragraphs.any?
      # Первый параграф - краткое описание, остальные - полное описание
      result[:short_description] ||= description_paragraphs.first if description_paragraphs.first.present?
      if description_paragraphs.length > 1
        result[:description] ||= description_paragraphs.join("\n\n")
      elsif description_paragraphs.length == 1
        result[:description] ||= description_paragraphs.first
      end
      Rails.logger.debug "PlDetailsFetcher.extract_description_from_modal: Extracted #{description_paragraphs.length} description paragraphs"
    end
  end
  
  def extract_designer_from_modal(modal, doc, result)
    # Ищем дизайнера в модальном окне
    # Структура: .pipf-product-details-modal__header содержит "Дизайнер", следующий .pipf-product-details-modal__label содержит имя
    modal.css('.pipf-product-details-modal__header').each do |header|
      header_text = header.text.strip.downcase
      if header_text.include?('дизайнер') || header_text.include?('designer') || header_text.include?('проектант') || header_text.include?('projektant')
        # Ищем следующий элемент с классом label
        label = header.parent.css('.pipf-product-details-modal__label').first || 
                header.next_element&.css('.pipf-product-details-modal__label')&.first ||
                header.parent.next_element&.css('.pipf-product-details-modal__label')&.first
        
        if label
          designer_value = label.text.strip
          if designer_value.present?
            result[:designer] = designer_value
            Rails.logger.debug "PlDetailsFetcher.extract_designer_from_modal: Found designer: #{result[:designer]}"
            return
          end
        end
      end
    end
    
    # Если не нашли, ищем в тексте страницы
    if result[:designer].blank?
      page_text = doc.text
      # Ищем имена дизайнеров IKEA (более полный список)
      designer_patterns = [
        /Maja\s+Ganszyniec/i,
        /Мая\s+Ганшинец/i,
        /IKEA\s+of\s+Sweden/i,
        /проектант[ка]?\s*:?\s*([А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+)/i,
        /designer[:\s]+([A-Z][a-z]+\s+[A-Z][a-z]+)/i
      ]
      
      designer_patterns.each do |pattern|
        match = page_text.match(pattern)
        if match
          result[:designer] = match[1] || match[0]
          Rails.logger.debug "PlDetailsFetcher.extract_designer_from_modal: Found designer in page text: #{result[:designer]}"
          break
        end
      end
    end
  end
  
  def extract_materials_and_care_from_modal(modal, doc, result)
    # Ищем секцию "Материалы и уход" по разным селекторам
    materials_section = find_section_by_id(modal, 'product-details-material-and-care') ||
                        find_section_by_text(modal, ['материал', 'material', 'materia', 'materiały', 'uho', 'уход', 'care', 'pielęgnacja', 'pielegnacja'])
    
    if materials_section
      # Извлекаем материалы
      materials_data = extract_materials_list(materials_section)
      if materials_data.any?
        result[:materials] ||= materials_data.join("\n")
        Rails.logger.debug "PlDetailsFetcher.extract_materials_and_care_from_modal: Extracted #{materials_data.length} material items"
      end
      
      # Извлекаем инструкции по уходу
      care_data = extract_care_instructions(materials_section)
      if care_data.any?
        result[:care_instructions] ||= care_data.join("\n")
        Rails.logger.debug "PlDetailsFetcher.extract_materials_and_care_from_modal: Extracted care instructions"
      end
    end
    
    # Если не нашли, ищем по всему документу
    if result[:materials].blank?
      extract_materials_from_document(doc, result)
    end
  end
  
  def extract_materials_list(section)
    materials_data = []
    
    # Ищем заголовок "Материалы"
    materials_header = section.css('h3, .pipf-product-details-modal__material-header, [class*="material-header"]').find { |h|
      text = h.text.downcase
      text.include?('материал') || text.include?('material')
    }
    
    return materials_data unless materials_header
    
    # Ищем все dl.pipf-product-details-modal__section элементы
    section.css('dl.pipf-product-details-modal__section, dl').each do |dl|
      dl.css('dt').each do |dt|
        dt_text = dt.text.strip
        next if dt_text.blank?
        
        # Ищем соответствующий dd элемент
        dd = find_next_dd(dt)
        dd_text = dd&.text&.strip if dd
        
        if dt_text.present? && dd_text.present?
          materials_data << "#{dt_text}: #{dd_text}"
        end
      end
    end
    
    # Если не нашли через dl, пробуем найти dt/dd напрямую в секции
    if materials_data.empty?
      section.css('dt').each do |dt|
        dt_text = dt.text.strip
        next if dt_text.blank?
        
        dd = find_next_dd(dt)
        dd_text = dd&.text&.strip if dd
        
        if dt_text.present? && dd_text.present?
          materials_data << "#{dt_text}: #{dd_text}"
        end
      end
    end
    
    materials_data
  end
  
  def find_next_dd(dt)
    # Ищем следующий dd элемент
    dd = dt.next_element
    while dd && dd.name != 'dd'
      dd = dd.next_element
    end
    
    # Если не нашли, пробуем найти в родительском элементе
    if dd.nil?
      parent = dt.parent
      if parent
        dt_index = parent.children.index(dt)
        if dt_index
          parent.children[dt_index + 1..-1].each do |sibling|
            if sibling.name == 'dd'
              dd = sibling
              break
            end
          end
        end
      end
    end
    
    dd
  end
  
  def extract_care_instructions(section)
    care_items = []
    
    # Ищем заголовок "Уход"
    care_header = section.css('h3, .pipf-product-details-modal__care-header, [class*="care-header"]').find { |h|
      text = h.text.downcase
      text.include?('уход') || text.include?('care') || text.include?('pielęgn') || text.include?('pielegn')
    }
    
    return care_items unless care_header
    
    # Ищем все элементы после заголовка ухода
    care_section = care_header.parent || care_header.next_element
    
    # Извлекаем заголовки и метки
    care_section.css('.pipf-product-details-modal__header, .pipf-product-details-modal__label, p').each do |el|
      text = el.text.strip
      care_items << text if text.present? && text.length > 3 && !text.match?(/^\d+$/)
    end
    
    care_items
  end
  
  def extract_materials_from_document(doc, result)
    # Ищем все dt/dd пары в документе, которые могут быть материалами
    doc.css('dl, dt').each do |el|
      if el.name == 'dt'
        dt_text = el.text.strip.downcase
        # Проверяем, похоже ли это на описание материала
        material_keywords = ['каркас', 'ткань', 'frame', 'fabric', 'пружин', 'spring', 'ножка', 'leg', 'подушка', 'cushion', 'видеоролик', 'video']
        if material_keywords.any? { |keyword| dt_text.include?(keyword) }
          dd = find_next_dd(el)
          dd_text = dd&.text&.strip if dd
          
          if dt_text.present? && dd_text.present?
            result[:materials] ||= []
            result[:materials] = (result[:materials].is_a?(Array) ? result[:materials] : [result[:materials]]).push("#{el.text.strip}: #{dd_text}").join("\n")
            Rails.logger.debug "PlDetailsFetcher.extract_materials_from_document: Found material: #{el.text.strip}"
          end
        end
      end
    end
  end
  
  def extract_safety_info_from_modal(modal, result)
    safety_section = find_section_by_id(modal, 'product-details-safety-and-compliance') ||
                     find_section_by_text(modal, ['безопасность', 'safety', 'соответствие', 'compliance', 'bezpieczeń', 'bezpieczen', 'zgodność', 'zgodnosc'])
    
    if safety_section
      safety_paragraphs = safety_section.css('.pipf-product-details-modal__paragraph, p, span.pipf-product-details-modal__paragraph').map(&:text).map(&:strip).compact.reject(&:empty?)
      if safety_paragraphs.any?
        result[:safety_info] ||= safety_paragraphs.join("\n\n")
        Rails.logger.debug "PlDetailsFetcher.extract_safety_info_from_modal: Extracted safety information"
      end
    end
  end
  
  def extract_good_to_know_from_modal(modal, result)
    good_to_know_section = find_section_by_id(modal, 'product-details-good-to-know') ||
                           find_section_by_text(modal, ['полезно знать', 'good to know', 'good-to-know', 'warto wied', 'warto wiedziec'])
    
    if good_to_know_section
      good_to_know_paragraphs = good_to_know_section.css('.pipf-product-details-modal__paragraph, p').map(&:text).map(&:strip).compact.reject(&:empty?)
      if good_to_know_paragraphs.any?
        result[:good_to_know] ||= good_to_know_paragraphs.join("\n\n")
        Rails.logger.debug "PlDetailsFetcher.extract_good_to_know_from_modal: Extracted 'good to know' information"
      end
    end
  end
  
  def extract_documents_from_modal(modal, doc, result)
    assembly_section = find_section_by_id(modal, 'product-details-assembly-and-documents') ||
                       find_section_by_text(modal, ['сборка', 'assembly', 'документ', 'document'])
    
    document_links = []
    
    if assembly_section
      # Ищем все ссылки на документы
      assembly_section.css('.pipf-product-details-modal__document-link, a[href*="assembly_instructions"], a[href*="manuals"]').each do |link|
        href = link['href']
        text = link.text.strip.gsub(/\s+/, ' ')
        # Удаляем номер статьи из текста, если есть
        text = text.gsub(/\d{3}\.\d{3}\.\d{2}/, '').strip
        
        if href.present?
          document_links << { url: href, title: text.presence || 'Документ' }
        end
      end
    end
    
    # Ищем ссылки на документы в HTML исходнике (модальное окно может быть в HTML, но скрыто)
    if document_links.empty?
      doc.css('a[href*="assembly_instructions"], a[href*="manuals"]').each do |link|
        href = link['href']
        text = link.text.strip
        if href.present?
          document_links << { url: href, title: text.presence || 'Документ' }
        end
      end
    end
    
    if document_links.any?
      result[:assembly_documents] = document_links.uniq { |d| self.class.canonical_document_url_for_dedupe(d[:url]) }
      Rails.logger.debug "PlDetailsFetcher.extract_documents_from_modal: Extracted #{result[:assembly_documents].length} document links"
    end
  end
  
  # Вспомогательные методы для поиска секций
  
  def find_section_by_id(modal, id_pattern)
    # Ищем секцию по ID (точное совпадение или частичное)
    modal.css("[id*='#{id_pattern}'], [id='#{id_pattern}']").first
  end
  
  def find_section_by_text(modal, keywords)
    # Ищем секцию по тексту (заголовок содержит ключевые слова)
    modal.css('*').find do |el|
      text = el.text.downcase
      keywords.any? { |keyword| text.include?(keyword.downcase) } &&
      (el.css('h3, h2, [class*="header"]').any? || el['id']&.include?('product-details'))
    end
  end
  
  def extract_from_scripts(doc, result)
    # Ищем данные модального окна в скриптах (модальное окно может быть загружено через JS)
    doc.css('script').each do |script|
      script_text = script.text
      
      # Ищем JSON с данными о продукте
      if script_text.include?('product-details') || script_text.include?('materials') || script_text.include?('designer')
        begin
          # Пробуем найти JSON объекты
          json_matches = script_text.scan(/\{[^{}]*(?:"materials"|"designer"|"care"|"safety")[^{}]*\}/m)
          json_matches.each do |json_str|
            begin
              json_data = JSON.parse(json_str)
              result[:materials] ||= json_data['materials'] if json_data['materials']
              result[:designer] ||= json_data['designer'] if json_data['designer']
              result[:care_instructions] ||= json_data['care'] if json_data['care']
              result[:safety_info] ||= json_data['safety'] if json_data['safety']
            rescue JSON::ParserError
              next
            end
          end
        rescue => e
          Rails.logger.debug "PlDetailsFetcher.extract_from_scripts: Error parsing script: #{e.message}"
        end
      end
    end
    
    # Также ищем данные напрямую в HTML исходнике (модальное окно может быть в HTML, но скрыто)
    html_source = doc.to_html
    
    # Ищем материалы по ключевым словам из предоставленного HTML
    if result[:materials].blank? && (html_source.include?('Каркас сиденья') || html_source.include?('Ткань') || html_source.include?('Карманные пружины'))
      Rails.logger.debug "PlDetailsFetcher.extract_from_scripts: Found material keywords in HTML source, trying to extract"
      # Пробуем найти структуру dt/dd в HTML исходнике
      extract_materials_from_html_source(doc, result)
    end
    
    # Ищем инструкции по уходу
    if result[:care_instructions].blank? && (html_source.include?('Пылесосить') || html_source.include?('Протрите чистой влажной тканью'))
      Rails.logger.debug "PlDetailsFetcher.extract_from_scripts: Found care keywords in HTML source"
      extract_care_from_html_source(doc, result)
    end
    
    # Ищем информацию о безопасности
    if result[:safety_info].blank? && (html_source.include?('Износостойкость') || html_source.include?('светостойкостью'))
      Rails.logger.debug "PlDetailsFetcher.extract_from_scripts: Found safety keywords in HTML source"
      extract_safety_from_html_source(doc, result)
    end
    
    # Ищем "Полезно знать"
    if result[:good_to_know].blank? && (html_source.include?('Крышка прикреплена') || html_source.include?('IKEA в Швеции'))
      Rails.logger.debug "PlDetailsFetcher.extract_from_scripts: Found good-to-know keywords in HTML source"
      extract_good_to_know_from_html_source(doc, result)
    end
  end
  
  def extract_materials_from_html_source(doc, result)
    # Ищем все dt/dd пары, которые могут быть материалами
    materials_data = []
    
    # Ищем по ключевым словам из предоставленного HTML (на русском и польском)
    material_keywords = [
      'Каркас сиденья', 'Карманные пружины', 'Нижняя часть рамы', 'Подушка спинки',
      'Видеоролик', 'Ткань', 'Каркас', 'пружин', 'ножка', 'подушка', 'видеоролик',
      'Frame', 'Spring', 'Leg', 'Cushion', 'Fabric',
      'Rama', 'Sprężyny', 'Noga', 'Poduszka', 'Tkanina', 'Materiał'
    ]
    
    # Ищем все dt элементы
    doc.css('dt').each do |dt_elem|
      dt_text = dt_elem.text.strip
      next if dt_text.blank?
      
      # Проверяем, содержит ли dt ключевые слова
      if material_keywords.any? { |keyword| dt_text.include?(keyword) }
        # Ищем соответствующий dd
        dd = find_next_dd(dt_elem)
        dd_text = dd&.text&.strip if dd
        
        if dt_text.present? && dd_text.present?
          materials_data << "#{dt_text}: #{dd_text}"
        end
      end
    end
    
    # Если не нашли через dt, ищем по тексту в HTML исходнике (более агрессивный поиск)
    if materials_data.empty?
      html_text = doc.text
      # Ищем известные пары из предоставленного HTML (на русском)
      known_materials_patterns = [
        [/Каркас\s+сиденья[:\s]+(.+?)(?:\n|Карманные|$)/i, 'Каркас сиденья'],
        [/Карманные\s+пружины[:\s]+(.+?)(?:\n|Нижняя|$)/i, 'Карманные пружины'],
        [/Нижняя\s+часть\s+рамы[:\s]+(.+?)(?:\n|Подушка|$)/i, 'Нижняя часть рамы/нога'],
        [/Подушка\s+спинки[:\s]+(.+?)(?:\n|Видеоролик|$)/i, 'Подушка спинки'],
        [/Видеоролик[:\s]+(.+?)(?:\n|Ткань|$)/i, 'Видеоролик'],
        [/Ткань[:\s]+(.+?)(?:\n|$)/i, 'Ткань']
      ]
      
      known_materials_patterns.each do |pattern, label|
        match = html_text.match(pattern)
        if match && match[1]
          value = match[1].strip
          if value.length > 5 && value.length < 500
            materials_data << "#{label}: #{value}"
          end
        end
      end
    end
    
    if materials_data.any?
      result[:materials] = materials_data.join("\n")
      Rails.logger.debug "PlDetailsFetcher.extract_materials_from_html_source: Extracted #{materials_data.length} materials from HTML source"
    end
  end
  
  def extract_care_from_html_source(doc, result)
    care_items = []
    
    # Ищем элементы с текстом об уходе
    care_keywords = ['Пылесосить', 'Протрите', 'чистой влажной тканью', 'Vacuum', 'Wipe', 'clean damp cloth', 'Odkurz', 'Przetrzyj']
    
    doc.css('p, span, [class*="label"]').each do |el|
      text = el.text.strip
      if care_keywords.any? { |keyword| text.include?(keyword) } && text.length > 5
        care_items << text
      end
    end
    
    # Если не нашли, ищем по тексту в HTML исходнике
    if care_items.empty?
      html_text = doc.text
      care_patterns = [
        /Рамка[^,]*,\s*несъемная\s+крышка[:\s]*\n*(.+?)(?:\n|Износостойкость|$)/i,
        /Пылесосить[\.]?\s*(.+?)(?:\n|Протрите|$)/i,
        /Протрите\s+чистой\s+влажной\s+тканью[\.]?\s*(.+?)(?:\n|$)/i
      ]
      
      care_patterns.each do |pattern|
        match = html_text.match(pattern)
        if match && match[1]
          value = match[1].strip
          care_items << value if value.length > 3 && value.length < 200
        end
      end
      
      # Также ищем известные фразы
      if html_text.include?('Пылесосить')
        care_items << 'Пылесосить.'
      end
      if html_text.include?('Протрите чистой влажной тканью')
        care_items << 'Протрите чистой влажной тканью.'
      end
    end
    
    if care_items.any?
      result[:care_instructions] = care_items.uniq.join("\n")
      Rails.logger.debug "PlDetailsFetcher.extract_care_from_html_source: Extracted care instructions from HTML source"
    end
  end
  
  def extract_safety_from_html_source(doc, result)
    safety_paragraphs = []
    
    # Ищем элементы с информацией о безопасности
    safety_keywords = ['Износостойкость', 'светостойкостью', 'испытания', 'стандартам', 'Wear resistance', 'lightfastness', 'tested', 'Wytrzymałość', 'odporność']
    
    doc.css('p, span, [class*="paragraph"]').each do |el|
      text = el.text.strip
      if safety_keywords.any? { |keyword| text.include?(keyword) } && text.length > 50
        safety_paragraphs << text
      end
    end
    
    # Если не нашли, ищем по тексту в HTML исходнике
    if safety_paragraphs.empty?
      html_text = doc.text
      safety_patterns = [
        /Износостойкость\s+этой\s+ткани\s+протестирована\s+на\s+(\d+)\s+циклов[\.]?\s*(.+?)(?:\n|Покрытие|$)/i,
        /Покрытие\s+обладает\s+светостойкостью\s+(\d+)[\.]?\s*(.+?)(?:\n|Данное|$)/i,
        /Данное\s+сиденье\s+прошло\s+испытания[\.]?\s*(.+?)(?:\n|$)/i
      ]
      
      safety_patterns.each do |pattern|
        match = html_text.match(pattern)
        if match
          if match[2]
            safety_paragraphs << match[0].strip
          elsif match[1]
            safety_paragraphs << match[0].strip
          end
        end
      end
    end
    
    if safety_paragraphs.any?
      result[:safety_info] = safety_paragraphs.uniq.join("\n\n")
      Rails.logger.debug "PlDetailsFetcher.extract_safety_from_html_source: Extracted safety info from HTML source"
    end
  end
  
  def extract_good_to_know_from_html_source(doc, result)
    good_to_know_paragraphs = []
    
    # Ищем элементы с информацией "Полезно знать"
    good_to_know_keywords = ['Крышка прикреплена', 'IKEA в Швеции', 'Cover attached', 'IKEA Sweden', 'Pokrywa przymocowana', 'IKEA Szwecja']
    
    doc.css('p, span, [class*="paragraph"]').each do |el|
      text = el.text.strip
      if good_to_know_keywords.any? { |keyword| text.include?(keyword) } && text.length > 10
        good_to_know_paragraphs << text
      end
    end
    
    # Если не нашли, ищем по тексту в HTML исходнике
    if good_to_know_paragraphs.empty?
      html_text = doc.text
      good_to_know_patterns = [
        /Крышка\s+прикреплена\s+намертво[\.]?\s*(.+?)(?:\n|IKEA|$)/i,
        /IKEA\s+в\s+Швеции\s+AB[\.]?\s*(.+?)(?:\n|$)/i
      ]
      
      good_to_know_patterns.each do |pattern|
        match = html_text.match(pattern)
        if match
          if match[1]
            good_to_know_paragraphs << match[0].strip
          else
            good_to_know_paragraphs << match[0].strip
          end
        end
      end
      
      # Также ищем известные фразы
      if html_text.include?('Крышка прикреплена намертво')
        good_to_know_paragraphs << 'Крышка прикреплена намертво.'
      end
      if html_text.include?('IKEA в Швеции')
        good_to_know_paragraphs << html_text.match(/IKEA\s+в\s+Швеции[^\.]+\./i)&.to_s
      end
    end
    
    if good_to_know_paragraphs.any?
      result[:good_to_know] = good_to_know_paragraphs.compact.uniq.join("\n\n")
      Rails.logger.debug "PlDetailsFetcher.extract_good_to_know_from_html_source: Extracted good-to-know from HTML source"
    end
  end
  
  # Извлечение информации о наличии из HTML
  def extract_availability(doc, product_data)
    availability = {}
    
    # Из productData
    if product_data
      stock_info = product_data.dig('stockcheckSection') || product_data.dig('stock') || product_data.dig('availability')
      if stock_info
        if stock_info.is_a?(Hash)
          quantity = stock_info['quantity'] || stock_info['availableQuantity'] || stock_info['stock']
          availability[:quantity] = quantity.to_i if quantity
          availability[:status] = stock_info['status'] || stock_info['availabilityStatus']
        end
      end

      # Вложенные статусы (часто HIGH_IN_STOCK / IN_STOCK)
      if availability[:status].blank?
        nested = product_data.dig('stockcheckSection', 'availability') ||
                 product_data.dig('stock', 'availability') ||
                 product_data.dig('availability', 'availability')
        if nested.is_a?(Hash)
          availability[:status] ||= nested['status'] || nested['type'] || nested['availabilityStatus']
          qn = nested['quantity'] || nested['availableQuantity']
          availability[:quantity] ||= qn.to_i if qn.present?
        end
      end
    end
    
    # Из HTML - ищем текст о наличии
    doc.css('[data-availability], [data-stock], .availability, .stock-status').each do |elem|
      text = elem.text.downcase
      if text.include?('dostępn') || text.include?('w magazynie') || text.include?('available')
        # Пробуем извлечь количество
        quantity_match = text.match(/(\d+)\s*(szt|sztuk|item|items)/i)
        if quantity_match
          availability[:quantity] = quantity_match[1].to_i
        else
          # Если просто "dostępne", ставим большое число
          availability[:quantity] = 999 if text.include?('dostępn')
        end
        availability[:status] = 'available'
      elsif text.include?('niedostępn') || text.include?('out of stock')
        availability[:quantity] = 0
        availability[:status] = 'unavailable'
      end
    end
    
    # Ищем в тексте страницы
    page_text = doc.text.downcase
    if page_text.include?('dostępne z dostawą') || page_text.include?('dostępny w')
      availability[:quantity] ||= 999
      availability[:status] ||= 'available'
    end
    
    availability
  end
  
  # Извлечение описания продукта и расширенных атрибутов (улучшенная версия на основе JS-парсера)
  def extract_product_description(doc, product_data)
    result = {}
    
    Rails.logger.debug "PlDetailsFetcher.extract_product_description: Starting extraction"
    
    # Описание из productData - расширенный список путей
    if product_data
      # Пути для описания
      description_paths = [
        ['productInformationSection', 'description'],
        ['productInformationSection', 'text'],
        ['productInformationSection', 'fullDescription'],
        ['productDescription'],
        ['description'],
        ['productDetails', 'description'],
        ['productDetails', 'text'],
        ['product', 'description'],
        ['product', 'text'],
        ['details', 'description'],
        ['details', 'text']
      ]
      
      description_paths.each do |path|
        desc = product_data.dig(*path)
        if desc.present?
          result[:description] = desc.is_a?(String) ? desc : desc.to_json
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found description in #{path.join('.')}"
          break
        end
      end
      
      # Пути для краткого описания
      short_desc_paths = [
        ['productInformationSection', 'shortDescription'],
        ['productInformationSection', 'summary'],
        ['shortDescription'],
        ['summary'],
        ['productDetails', 'shortDescription'],
        ['productDetails', 'summary']
      ]
      
      short_desc_paths.each do |path|
        short_desc = product_data.dig(*path)
        if short_desc.present?
          result[:short_description] = short_desc.is_a?(String) ? short_desc : short_desc.to_json
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found short_description in #{path.join('.')}"
          break
        end
      end
      
      # Материалы - расширенный поиск
      materials_paths = [
        ['productInformationSection', 'materials'],
        ['productInformationSection', 'materialInfo'],
        ['productInformationSection', 'materials', 'text'],
        ['productInformationSection', 'materials', 'items'],
        ['materials'],
        ['materialInfo'],
        ['productDetails', 'materials'],
        ['productDetails', 'materialInfo']
      ]
      
      materials_paths.each do |path|
        materials = product_data.dig(*path)
        if materials.present?
          # Если это массив, преобразуем в строку
          if materials.is_a?(Array)
            result[:materials] = materials.map { |m| m.is_a?(Hash) ? (m['text'] || m['name'] || m.to_s) : m.to_s }.join("\n")
          elsif materials.is_a?(Hash)
            result[:materials] = materials['text'] || materials['name'] || materials.to_json
          else
            result[:materials] = materials.to_s
          end
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found materials in #{path.join('.')}"
          break
        end
      end
      
      # Характеристики (features) - расширенный поиск
      features_paths = [
        ['productInformationSection', 'features'],
        ['productInformationSection', 'characteristics'],
        ['productInformationSection', 'features', 'items'],
        ['productInformationSection', 'features', 'text'],
        ['features'],
        ['characteristics'],
        ['productDetails', 'features'],
        ['productDetails', 'characteristics']
      ]
      
      features_paths.each do |path|
        features = product_data.dig(*path)
        if features.present?
          # Если это массив, сохраняем как массив
          if features.is_a?(Array)
            result[:features] = features.map { |f| f.is_a?(Hash) ? (f['text'] || f['name'] || f.to_s) : f.to_s }
          elsif features.is_a?(Hash)
            # Если это объект с items или text
            if features['items'].is_a?(Array)
              result[:features] = features['items'].map { |f| f.is_a?(Hash) ? (f['text'] || f['name'] || f.to_s) : f.to_s }
            elsif features['text'].present?
              result[:features] = [features['text']]
            else
              result[:features] = [features.to_json]
            end
          else
            result[:features] = [features.to_s]
          end
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found features in #{path.join('.')}"
          break
        end
      end
      
      # Инструкции по уходу
      care_paths = [
        ['productInformationSection', 'careInstructions'],
        ['productInformationSection', 'care', 'instructions'],
        ['careInstructions'],
        ['care', 'instructions'],
        ['productDetails', 'careInstructions']
      ]
      
      care_paths.each do |path|
        care = product_data.dig(*path)
        if care.present?
          if care.is_a?(Array)
            result[:care_instructions] = care.map { |c| c.is_a?(Hash) ? (c['text'] || c['name'] || c.to_s) : c.to_s }.join("\n")
          elsif care.is_a?(Hash)
            result[:care_instructions] = care['text'] || care['name'] || care.to_json
          else
            result[:care_instructions] = care.to_s
          end
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found care_instructions in #{path.join('.')}"
          break
        end
      end
      
      # Экологическая информация
      env_paths = [
        ['productInformationSection', 'environmentalInformation'],
        ['productInformationSection', 'environmentalInfo'],
        ['productInformationSection', 'environment', 'info'],
        ['environmentalInformation'],
        ['environmentalInfo'],
        ['environment', 'info'],
        ['productDetails', 'environmentalInformation']
      ]
      
      env_paths.each do |path|
        env_info = product_data.dig(*path)
        if env_info.present?
          if env_info.is_a?(Array)
            result[:environmental_info] = env_info.map { |e| e.is_a?(Hash) ? (e['text'] || e['name'] || e.to_s) : e.to_s }.join("\n")
          elsif env_info.is_a?(Hash)
            result[:environmental_info] = env_info['text'] || env_info['name'] || env_info.to_json
          else
            result[:environmental_info] = env_info.to_s
          end
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found environmental_info in #{path.join('.')}"
          break
        end
      end
    end
    
    # Извлечение из HTML (fallback)
    # Описание
    if result[:description].blank?
      description_selectors = [
        '.pip-product-information',
        '.pip-product-description',
        '.product-description',
        '[data-product-description]',
        '.pip-product-details-content',
        '.pip-overview__description',
        '.pip-product-details__description'
      ]
      
      description_selectors.each do |selector|
        desc_elem = doc.css(selector).first
        if desc_elem
          result[:description] = desc_elem.inner_html.strip
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found description in HTML selector: #{selector}"
          break if result[:description].present?
        end
      end
    end
    
    # Краткое описание
    if result[:short_description].blank?
      short_desc_selectors = [
        '.pip-header-section__description',
        '.pip-overview__short-description',
        '.product-short-description',
        '[data-short-description]'
      ]
      
      short_desc_selectors.each do |selector|
        short_desc_elem = doc.css(selector).first
        if short_desc_elem
          result[:short_description] = short_desc_elem.inner_html.strip
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found short_description in HTML selector: #{selector}"
          break if result[:short_description].present?
        end
      end
    end
    
    # Материалы из HTML
    if result[:materials].blank?
      materials_selectors = [
        '#materials-details',
        '.pip-materials',
        '[data-materials]',
        '.pip-product-details__materials',
        '.product-materials'
      ]
      
      materials_selectors.each do |selector|
        materials_elem = doc.css(selector).first
        if materials_elem
          result[:materials] = materials_elem.inner_html.strip
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found materials in HTML selector: #{selector}"
          break if result[:materials].present?
        end
      end
    end
    
    # Характеристики из HTML
    if result[:features].blank?
      features_selectors = [
        '.pip-product-features li',
        '.product-features li',
        '[data-feature]',
        '.pip-characteristics li',
        '.product-characteristics li'
      ]
      
      features_selectors.each do |selector|
        features_elems = doc.css(selector)
        if features_elems.any?
          result[:features] = features_elems.map(&:text).map(&:strip).compact.reject(&:empty?)
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found #{result[:features].length} features in HTML selector: #{selector}"
          break if result[:features].any?
        end
      end
    end
    
    # Инструкции по уходу из HTML
    if result[:care_instructions].blank?
      care_selectors = [
        '.pip-care-instructions__text',
        '.pip-care-instructions',
        '.care-instructions',
        '[data-care-instructions]'
      ]
      
      care_selectors.each do |selector|
        care_elem = doc.css(selector).first
        if care_elem
          result[:care_instructions] = care_elem.inner_html.strip
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found care_instructions in HTML selector: #{selector}"
          break if result[:care_instructions].present?
        end
      end
    end
    
    # Экологическая информация из HTML
    if result[:environmental_info].blank?
      env_selectors = [
        '.pip-environmental-info__text',
        '.pip-environmental-information',
        '.environmental-info',
        '[data-environmental-info]'
      ]
      
      env_selectors.each do |selector|
        env_elem = doc.css(selector).first
        if env_elem
          result[:environmental_info] = env_elem.inner_html.strip
          Rails.logger.debug "PlDetailsFetcher.extract_product_description: Found environmental_info in HTML selector: #{selector}"
          break if result[:environmental_info].present?
        end
      end
    end
    
    Rails.logger.info "PlDetailsFetcher.extract_product_description: Extracted - description: #{result[:description].present?}, short_description: #{result[:short_description].present?}, materials: #{result[:materials].present?}, features: #{result[:features].present?}, care_instructions: #{result[:care_instructions].present?}, environmental_info: #{result[:environmental_info].present?}"
    result.compact
  end
  
  def extract_images(doc, product_data, _existing_images = [])
    # В images сохраняем только реальные фото из модального окна галереи товара (PIPF),
    # чтобы не попадали служебные/иконки/шумы из остальной страницы.
    modal = doc.at_css("[class*='pipf-product-gallery-modal']")
    modal ||= doc.at_css(".pipf-product-gallery")
    modal ||= doc.at_css(".pipf-product-gallery__media")
    unless modal
      Rails.logger.info "PlDetailsFetcher.extract_images: gallery modal not found (.pipf-product-gallery-modal)"
      return []
    end

    pairs = []

    modal.css("img").each do |img|
      collect_gallery_candidate_urls_for_node(img, pairs)
    end

    modal.css("a[href]").each do |a|
      raw = a["href"].to_s.strip
      u = normalize_pipf_gallery_image_url(raw)
      pairs << { url: u, node: a } if u
    end

    modal.css("[data-image-url], [data-image-src], [data-product-image]").each do |el|
      %w[data-image-url data-image-src data-product-image].each do |attr|
        raw = el[attr].to_s.strip
        u = normalize_pipf_gallery_image_url(raw)
        pairs << { url: u, node: el } if u
      end
    end

    images = pairs.filter_map { |p| p[:url] }.uniq
    target = normalize_product_token(@scope_sku) if @scope_sku.present?

    if target.present?
      scoped = scope_gallery_urls_to_item(images, pairs, modal, product_data, target)
      if scoped.any?
        Rails.logger.info "PlDetailsFetcher.extract_images: scoped to SKU #{target}, #{scoped.length}/#{images.length} gallery URLs"
        return scoped
      end

      Rails.logger.warn "PlDetailsFetcher.extract_images: scope_sku=#{@scope_sku} but no scoped gallery match; keeping #{images.length} unfiltered URLs"
    end

    Rails.logger.info "PlDetailsFetcher.extract_images: Extracted #{images.length} gallery images from modal"
    images
  end

  def collect_gallery_candidate_urls_for_node(node, pairs)
    candidates = [
      node["src"],
      node["data-src"],
      node["data-lazy-src"],
      node["data-original"],
      node["data-image"]
    ].compact

    srcset = node["srcset"].to_s
    if srcset.present?
      srcset.split(",").each do |part|
        candidate = part.to_s.strip.split(/\s+/).first
        candidates << candidate if candidate.present?
      end
    end

    candidates.each do |raw|
      u = normalize_pipf_gallery_image_url(raw)
      pairs << { url: u, node: node } if u
    end
  end

  def normalize_pipf_gallery_image_url(raw)
    return nil if raw.blank?
    url = raw.to_s.strip
    return nil if url.blank?
    url = "https://www.ikea.com#{url}" if url.start_with?("/")
    return nil unless url.start_with?("http://", "https://")
    return nil if url.match?(/pvid/i)

    normalized = url.split("?").first
    return nil unless normalized.match?(/\.(jpg|jpeg|png|webp)\z/i)
    return nil if normalized.match?(/placeholder|icon|logo|sprite/i)
    return nil unless normalized.include?("ikea.com")

    normalized
  end

  def scope_gallery_urls_to_item(all_urls, pairs, modal, product_data, target)
    dom_urls =
      pairs.filter_map do |p|
        next unless gallery_dom_node_matches_item?(p[:node], modal, target)

        p[:url]
      end.uniq
    return dom_urls if dom_urls.any?

    hyd = gallery_urls_for_item_from_product_data(product_data, target)
    return hyd if hyd.any?

    pat = all_urls.select { |u| gallery_url_matches_item_pattern?(u, target) }
    pat.uniq.presence || []
  end

  def gallery_dom_node_matches_item?(node, modal_root, target)
    return false unless node && modal_root && target.present?

    el = node
    loop do
      %w[data-item-no data-product-id data-sku data-item-no-global].each do |attr|
        token = el[attr]
        norm = normalize_product_token(token)
        return true if norm == target
      end
      break if el == modal_root

      el = el.parent
      break unless el
    end

    false
  end

  def gallery_urls_for_item_from_product_data(product_data, target)
    return [] unless product_data.is_a?(Hash) && target.present?

    raw = []
    collect_gallery_urls_for_item_in_json(product_data, target, raw, 0)
    raw.filter_map { |u| normalize_pipf_gallery_image_url(u) }.uniq
  end

  def collect_gallery_urls_for_item_in_json(obj, target, acc, depth)
    return if depth > 18

    case obj
    when Hash
      item_no = normalize_product_token(extract_item_no_from_hash(obj))
      if item_no == target
        u = extract_media_url_from_gallery_entry(obj)
        acc << u if u.present?
      end
      obj.each_value { |v| collect_gallery_urls_for_item_in_json(v, target, acc, depth + 1) }
    when Array
      obj.each { |v| collect_gallery_urls_for_item_in_json(v, target, acc, depth + 1) }
    end
  end

  def extract_media_url_from_gallery_entry(h)
    return nil unless h.is_a?(Hash)

    u =
      h.dig("content", "url") ||
      h.dig("content", "src") ||
      h["url"] ||
      h["src"] ||
      h["contentUrl"] ||
      h["imageUrl"] ||
      (h["image"].is_a?(String) ? h["image"] : nil)
    u = u["url"] if u.is_a?(Hash) && u["url"]
    u.to_s.strip.presence
  end

  def gallery_url_matches_item_pattern?(url, target)
    u = url.to_s.downcase
    t = target.to_s.downcase
    return true if t.present? && u.include?(t)

    digits = t.delete("^0-9")
    return false if digits.length < 8

    u.include?(digits)
  end

  def browser_mode
    @browser_mode ||= begin
      mode = ENV.fetch('PL_FETCHER_BROWSER_MODE', 'new').to_s.strip.downcase
      %w[new full].include?(mode) ? mode : 'new'
    end
  end

  def full_browser_mode?
    browser_mode == 'full'
  end
end

