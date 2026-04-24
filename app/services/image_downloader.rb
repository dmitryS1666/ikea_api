# frozen_string_literal: true

require "json"
require "set"
require "digest"
require "open-uri"
require "fileutils"
require "pathname"
require "open3"
require "tempfile"

class ImageDownloader
  DEFAULT_OPEN_TIMEOUT = 20
  DEFAULT_READ_TIMEOUT = 20

  class << self
    # Главная точка входа для джобы
    def sync_product_images(product, limit: nil)
      image_urls = normalize_remote_urls(normalize_string_array(product.images))
      image_urls = image_urls.first(limit) if limit.present?

      current_local_images = normalize_string_array(product.local_images)
      healthy_local_images = unique_healthy_paths(current_local_images)
      healthy_local_images = keep_only_paths_for_urls(healthy_local_images, image_urls) if image_urls.any?

      changed = false

      # 1. Сначала очищаем local_images от битых/несуществующих/дублей
      if healthy_local_images != current_local_images
        persist_local_images!(product, healthy_local_images)
        changed = true
      end

      return build_sync_result(
        changed: changed,
        downloaded: [],
        skipped: [],
        failed: [],
        final_local_images: healthy_local_images
      ) if image_urls.empty?

      target_count = limit.presence || image_urls.size
      if healthy_local_images.size >= target_count
        changed ||= convert_local_images_to_webp(product)

        return build_sync_result(
          changed: changed,
          downloaded: [],
          skipped: [],
          failed: [],
          final_local_images: healthy_local_images.first(target_count)
        )
      end

      download_result = download_product_images(
        product,
        image_urls,
        limit: target_count,
        existing_paths: healthy_local_images
      )

      final_local_images = unique_healthy_paths(download_result[:final_local_images])

      persisted_now = normalize_string_array(product.reload.local_images)
      if persisted_now != final_local_images
        persist_local_images!(product, final_local_images)
        changed = true
      end

      webp_changed = convert_local_images_to_webp(product)
      changed ||= webp_changed

      build_sync_result(
        changed: changed || download_result[:changed],
        downloaded: download_result[:downloaded],
        skipped: download_result[:skipped],
        failed: download_result[:failed],
        final_local_images: final_local_images
      )
    end

    # Низкоуровневая загрузка недостающих картинок
    def download_product_images(product, image_urls, limit: nil, existing_paths: nil)
      urls = normalize_remote_urls(normalize_string_array(image_urls))
      current_paths = existing_paths ? normalize_string_array(existing_paths) : unique_healthy_paths(normalize_string_array(product.local_images))

      result = {
        changed: false,
        downloaded: [],
        skipped: [],
        failed: [],
        final_local_images: current_paths.dup
      }

      return result if urls.empty?

      final_paths = current_paths.dup
      seen_urls = Set.new
      content_fingerprints = build_existing_fingerprints(final_paths)

      target_count = limit.presence || urls.size

      urls.each do |url|
        break if final_paths.size >= target_count
        next if url.blank?
        normalized_url = normalize_remote_image_url(url)
        next if normalized_url.blank?
        next if seen_urls.include?(normalized_url)

        seen_urls << normalized_url

        if already_downloaded_for_url?(product, normalized_url, final_paths)
          result[:skipped] << { url: url, reason: "already_downloaded" }
          next
        end

        begin
          downloaded_path = download_single_image(product, normalized_url)

          unless downloaded_path.present?
            result[:failed] << { url: url, reason: "empty_path" }
            next
          end

          unless local_image_ref_healthy?(downloaded_path)
            purge_local_image_ref!(downloaded_path)
            result[:failed] << { url: url, reason: "unhealthy_file" }
            next
          end

          fingerprint = fingerprint_for_path(downloaded_path)

          if fingerprint.present? && content_fingerprints.include?(fingerprint)
            purge_local_image_ref!(downloaded_path)
            result[:skipped] << { url: url, reason: "duplicate_content" }
            next
          end

          if final_paths.include?(downloaded_path)
            purge_local_image_ref!(downloaded_path)
            result[:skipped] << { url: url, reason: "duplicate_path" }
            next
          end

          final_paths << downloaded_path
          result[:downloaded] << downloaded_path
          content_fingerprints << fingerprint if fingerprint.present?
          result[:changed] = true
        rescue StandardError => e
          result[:failed] << {
            url: url,
            reason: "download_error",
            error: e.message
          }
        end
      end

      result[:final_local_images] = unique_healthy_paths(final_paths).first(target_count)
      result
    end

    private

    def build_sync_result(changed:, downloaded:, skipped:, failed:, final_local_images:)
      {
        changed: changed,
        downloaded: downloaded,
        skipped: skipped,
        failed: failed,
        final_local_images: final_local_images
      }
    end

    def download_single_image(_product, url)
      existing = ProductLocalImages.find_existing_blob_for_url(url)
      return ProductLocalImages.encode_ref(existing) if existing

      io = download_remote_io(url)
      return nil unless io

      begin
        final_io, content_type, filename = build_upload_io_and_meta(url, io)
        blob =
          ActiveStorage::Blob.create_and_upload!(
            io: final_io,
            filename: filename,
            content_type: content_type
          )
        ProductLocalImages.ensure_etalon_mirror!(blob)
        ProductLocalImages.encode_ref(blob)
      ensure
        io.close! if io.is_a?(Tempfile)
      end
    end

    def normalize_string_array(value)
      case value
      when Array
        value.map(&:to_s).map(&:strip).reject(&:blank?)
      when String
        begin
          parsed = JSON.parse(value)
          parsed.is_a?(Array) ? parsed.map(&:to_s).map(&:strip).reject(&:blank?) : []
        rescue JSON::ParserError
          []
        end
      else
        []
      end
    end

    def normalize_remote_urls(urls)
      urls.filter_map { |url| normalize_remote_image_url(url) }.uniq
    end

    def normalize_remote_image_url(url)
      raw = url.to_s.strip
      return nil if raw.blank?

      # IKEA часто отдаёт protocol-relative URL: //www.ikea.com/...
      raw = "https:#{raw}" if raw.start_with?("//")

      # HTML-листинг иногда кладёт относительный путь без схемы: /globalassets/...
      raw = "https://www.ikea.com#{raw}" if raw.start_with?("/")

      uri = URI.parse(raw)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.fragment = nil
      # Раньше мы отбрасывали любые URL, где встречалось "pvid" — это ломало нормальные CDN-ссылки IKEA.
      # Убираем только query-параметр pvid (если есть), остальные параметры сохраняем.
      if uri.query.present?
        pairs = URI.decode_www_form(uri.query)
        filtered = pairs.reject { |k, _| k.to_s.casecmp("pvid").zero? }
        uri.query =
          if filtered.empty?
            nil
          else
            URI.encode_www_form(filtered)
          end
      end

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def unique_healthy_paths(paths)
      seen = Set.new

      paths.each_with_object([]) do |path, result|
        next if path.blank?
        next if seen.include?(path)
        next unless local_image_ref_healthy?(path)

        seen << path
        result << path
      end
    end

    def persist_local_images!(product, paths)
      attribute_type = product.class.type_for_attribute("local_images").type

      value =
        if [:json, :jsonb].include?(attribute_type)
          paths
        else
          paths.to_json
        end

      product.update_column(:local_images, value)
    end

    def convert_local_images_to_webp(product)
      return false unless defined?(Products::ConvertLocalImagesToWebpService)
      paths = normalize_string_array(product.local_images)
      return false if paths.empty?
      return false if paths.all? { |p| ProductLocalImages.blob_ref?(p) }

      result =
        Products::ConvertLocalImagesToWebpService.new(
          scope: Product.where(id: product.id),
          dry_run: false,
          batch_size: 1
        ).call

      result.updated_products.to_i.positive? || result.converted_images.to_i.positive?
    rescue StandardError => e
      Rails.logger.warn("ImageDownloader: webp conversion skipped for sku=#{product.sku}: #{e.class} #{e.message}")
      false
    end

    def detect_extension(url, content_type)
      ext = File.extname(URI.parse(url).path).to_s.downcase
      return ext if ext.present? && ext.match?(/\A\.[a-z0-9]+\z/)

      case content_type.to_s.downcase
      when "image/jpeg", "image/jpg" then ".jpg"
      when "image/png" then ".png"
      when "image/webp" then ".webp"
      when "image/gif" then ".gif"
      when "image/avif" then ".avif"
      else
        ".jpg"
      end
    rescue URI::InvalidURIError
      ".jpg"
    end

    def already_downloaded_for_url?(_product, url, current_paths)
      normalized = normalize_remote_image_url(url)
      return false if normalized.blank?

      existing = ProductLocalImages.find_existing_blob_for_url(normalized)
      return false unless existing

      ref = ProductLocalImages.encode_ref(existing)
      return true if current_paths.include?(ref)

      current_paths.any? do |path|
        next false unless ProductLocalImages.blob_ref?(path)

        ProductLocalImages.blob_from_ref(path)&.id == existing.id
      rescue StandardError
        false
      end
    end

    def build_existing_fingerprints(paths)
      paths.each_with_object(Set.new) do |path, acc|
        fingerprint = fingerprint_for_path(path)
        acc << fingerprint if fingerprint.present?
      end
    end

    # Оставляем только local_images, которые соответствуют текущим remote URLs товара.
    # Это предотвращает «залипание» чужих картинок после смены списка product.images.
    def keep_only_paths_for_urls(paths, image_urls)
      return [] if image_urls.blank?

      expected_bases =
        image_urls.filter_map do |url|
          normalized = normalize_remote_image_url(url)
          next if normalized.blank?
          ProductLocalImages.deterministic_base_filename(normalized)
        end.to_set

      return [] if expected_bases.empty?

      paths.select do |path|
        base = base_filename_for_local_ref(path)
        base.present? && expected_bases.include?(base)
      end
    end

    def base_filename_for_local_ref(path)
      if ProductLocalImages.blob_ref?(path)
        blob = ProductLocalImages.blob_from_ref(path)
        return nil unless blob
        return blob.filename.to_s.sub(/\.[^.]+\z/, "")
      end

      absolute_path = absolute_local_path(path)
      return nil if absolute_path.blank?

      File.basename(absolute_path.to_s).sub(/\.[^.]+\z/, "")
    rescue StandardError
      nil
    end

    def fingerprint_for_path(path)
      if ProductLocalImages.blob_ref?(path)
        blob = ProductLocalImages.blob_from_ref(path)
        return nil unless blob

        return blob.checksum if blob.checksum.present?

        return Digest::SHA256.hexdigest(blob.download)
      end

      absolute_path = absolute_local_path(path)
      return nil unless absolute_path.present?
      return nil unless File.exist?(absolute_path)
      return nil unless File.file?(absolute_path)

      Digest::SHA256.file(absolute_path).hexdigest
    rescue StandardError
      nil
    end

    def purge_local_image_ref!(path)
      if ProductLocalImages.blob_ref?(path)
        ProductLocalImages.purge_ref!(path)
        return
      end

      absolute_path = absolute_local_path(path)
      return if absolute_path.blank?
      return unless File.exist?(absolute_path)

      File.delete(absolute_path)
    rescue StandardError
      nil
    end

    def local_image_ref_healthy?(path)
      return ProductLocalImages.ref_healthy?(path) if ProductLocalImages.blob_ref?(path)

      ImageStorage::Local.healthy?(path)
    end

    def download_remote_io(url)
      io =
        if defined?(ProxyRotator)
          ProxyRotator.with_proxy_retry do |proxy_options|
            URI.open(
              url,
              open_timeout: DEFAULT_OPEN_TIMEOUT,
              read_timeout: DEFAULT_READ_TIMEOUT,
              proxy_http_basic_authentication: proxy_options ? [
                "http://#{proxy_options[:http_proxyaddr]}:#{proxy_options[:http_proxyport]}",
                proxy_options[:http_proxyuser],
                proxy_options[:http_proxypass]
              ] : nil,
              "User-Agent" => ENV.fetch("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            )
          end
        else
          URI.open(
            url,
            open_timeout: DEFAULT_OPEN_TIMEOUT,
            read_timeout: DEFAULT_READ_TIMEOUT,
            "User-Agent" => ENV.fetch("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
          )
        end

      tmp = Tempfile.new(["product_img_dl", ".bin"])
      tmp.binmode
      tmp.write(io.read)
      tmp.flush
      tmp.rewind
      tmp
    ensure
      io&.close if io.respond_to?(:close)
    end

    def build_upload_io_and_meta(url, io)
      io.rewind
      base = ProductLocalImages.deterministic_base_filename(url)
      ext = detect_extension(url, nil)
      src = nil
      dst = nil

      cwebp_ok =
        begin
          _stdout, _stderr, st = Open3.capture3("cwebp", "-version")
          st.success?
        rescue StandardError
          false
        end

      if cwebp_ok && %w[.jpg .jpeg .png .webp].include?(ext.downcase)
        bytes = io.read
        src = Tempfile.new([base, ext.to_s])
        src.binmode
        src.write(bytes)
        src.flush
        dst = Tempfile.new([base, ".webp"])
        dst.close
        _o, err, st = Open3.capture3(
          "cwebp", "-q", "82", "-m", "6", "-af", "-sharp_yuv", "-mt", src.path, "-o", dst.path
        )
        if st.success? && File.exist?(dst.path) && File.size?(dst.path).to_i.positive?
          return [StringIO.new(File.binread(dst.path)), "image/webp", "#{base}.webp"]
        end

        Rails.logger.warn("ImageDownloader: cwebp failed for #{url}: #{err.to_s.strip.presence || 'unknown'}")
      end

      io.rewind
      [StringIO.new(io.read), marcel_mime(ext, nil), "#{base}#{ext}"]
    ensure
      src&.close!
      dst&.close!
    end

    def marcel_mime(ext, content_type)
      ct = content_type.to_s.strip.presence
      return ct if ct.present?

      case ext.downcase
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".png" then "image/png"
      when ".webp" then "image/webp"
      else
        "application/octet-stream"
      end
    end

    def absolute_local_path(path)
      return nil if path.blank?

      raw = path.to_s.strip
      if raw.match?(%r{\A/(images|uploads)/}i)
        return Rails.root.join("public", raw.delete_prefix("/")).to_s
      end

      pathname = Pathname.new(raw)

      if pathname.absolute?
        pathname.to_s
      elsif ImageStorage::Local.respond_to?(:path_for)
        ImageStorage::Local.path_for(path)
      else
        Rails.root.join(path).to_s
      end
    end
  end
end
