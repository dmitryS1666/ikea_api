# frozen_string_literal: true

require "json"
require "set"
require "digest"
require "open-uri"
require "fileutils"
require "pathname"

class ImageDownloader
  DEFAULT_OPEN_TIMEOUT = 20
  DEFAULT_READ_TIMEOUT = 20

  class << self
    # Главная точка входа для джобы
    def sync_product_images(product, limit: nil)
      image_urls = normalize_string_array(product.images).uniq
      image_urls = image_urls.first(limit) if limit.present?

      current_local_images = normalize_string_array(product.local_images)
      healthy_local_images = unique_healthy_paths(current_local_images)

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
      urls = normalize_string_array(image_urls).uniq
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
        next if seen_urls.include?(url)

        seen_urls << url

        if already_downloaded_for_url?(product, url, final_paths)
          result[:skipped] << { url: url, reason: "already_downloaded" }
          next
        end

        begin
          downloaded_path = download_single_image(product, url)

          unless downloaded_path.present?
            result[:failed] << { url: url, reason: "empty_path" }
            next
          end

          unless ImageStorage::Local.healthy?(downloaded_path)
            safe_delete_local_file(downloaded_path)
            result[:failed] << { url: url, reason: "unhealthy_file" }
            next
          end

          fingerprint = fingerprint_for_path(downloaded_path)

          if fingerprint.present? && content_fingerprints.include?(fingerprint)
            safe_delete_local_file(downloaded_path)
            result[:skipped] << { url: url, reason: "duplicate_content" }
            next
          end

          if final_paths.include?(downloaded_path)
            safe_delete_local_file(downloaded_path)
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

    def download_single_image(product, url)
      io = URI.open(
        url,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT
      )

      content_type =
        if io.respond_to?(:content_type)
          io.content_type
        elsif io.respond_to?(:meta) && io.meta.is_a?(Hash)
          io.meta["content-type"]
        end

      extension = detect_extension(url, content_type)
      filename = build_filename(product, url, extension)
      folder = product_images_folder(product)

      # Подстрой под свой реальный интерфейс хранилища,
      # если метод называется иначе.
      ImageStorage::Local.save(
        io.read,
        filename: filename,
        folder: folder
      )
    ensure
      io&.close if defined?(io) && io.respond_to?(:close)
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

    def unique_healthy_paths(paths)
      seen = Set.new

      paths.each_with_object([]) do |path, result|
        next if path.blank?
        next if seen.include?(path)
        next unless ImageStorage::Local.healthy?(path)

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

    def product_images_folder(product)
      identifier = product.id.presence || product.sku.presence || "unknown_product"
      "products/#{identifier}"
    end

    def build_filename(product, url, extension)
      prefix = build_filename_prefix(product, url)
      "#{prefix}#{extension}"
    end

    def build_filename_prefix(product, url)
      identifier = product.sku.presence || product.id
      url_hash = Digest::SHA256.hexdigest(url)[0, 16]
      [identifier, url_hash].compact.join("_")
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

    def already_downloaded_for_url?(product, url, current_paths)
      expected_prefix = build_filename_prefix(product, url)

      current_paths.any? do |path|
        next false unless ImageStorage::Local.healthy?(path)

        File.basename(path).start_with?(expected_prefix)
      end
    end

    def build_existing_fingerprints(paths)
      paths.each_with_object(Set.new) do |path, acc|
        fingerprint = fingerprint_for_path(path)
        acc << fingerprint if fingerprint.present?
      end
    end

    def fingerprint_for_path(path)
      absolute_path = absolute_local_path(path)
      return nil unless absolute_path.present?
      return nil unless File.exist?(absolute_path)
      return nil unless File.file?(absolute_path)

      Digest::SHA256.file(absolute_path).hexdigest
    rescue StandardError
      nil
    end

    def safe_delete_local_file(path)
      absolute_path = absolute_local_path(path)
      return if absolute_path.blank?
      return unless File.exist?(absolute_path)

      File.delete(absolute_path)
    rescue StandardError
      nil
    end

    def absolute_local_path(path)
      return nil if path.blank?

      pathname = Pathname.new(path.to_s)

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
