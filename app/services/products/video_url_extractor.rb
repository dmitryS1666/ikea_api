# frozen_string_literal: true

module Products
  # Собирает ссылки на видео товара: колонка videos, картинки, full_attributes, HTML PIP.
  class VideoUrlExtractor
    VIDEO_EXT_RE = /\.(mp4|webm|mov|m4v)(?:\?|#|\z)/i
    EMBED_RE = %r{(?:youtube\.com|youtu\.be|vimeo\.com|player\.vimeo\.com)}i
    IKEA_PVID_RE = %r{(?:https?:)?//(?:www\.)?ikea\.com/pvid/[^\s"'<>\\]+}i
    ABSOLUTE_URL_RE = %r{https?://[^\s"'<>\\]+}i
    URL_KEYS = %w[url src href videoUrl video_url contentUrl content_url fileUrl file_url].freeze
    MAX_WALK_NODES = 2_000

    class << self
      def urls_from_product(product)
        urls = []
        urls.concat(urls_from_value(product.videos))
        urls.concat(urls_from_value(product.images))
        urls.concat(urls_from_value(product.full_attributes))
        normalize_list(urls)
      end

      def urls_from_html(html)
        text = html.to_s
        return [] if text.blank?

        urls = text.scan(ABSOLUTE_URL_RE)
        text.scan(IKEA_PVID_RE).each do |raw|
          urls << (raw.start_with?("http") ? raw : "https:#{raw}")
        end
        normalize_list(urls)
      end

      def urls_from_value(value)
        normalize_list(collect_urls(value, 0, 0))
      end

      def downloadable?(url)
        classify(url) == :file
      end

      def embed?(url)
        classify(url) == :embed
      end

      def classify(url)
        normalized = normalize_url(url)
        return :other if normalized.blank?
        return :embed if normalized.match?(EMBED_RE)
        return :file if video_file?(normalized)

        :other
      end

      def video_file?(url)
        return false if url.blank?
        return true if url.match?(VIDEO_EXT_RE)
        return true if url.match?(%r{/pvid/}i) && !image_poster?(url)

        false
      end

      def normalize_url(url)
        value = url.to_s.strip
        return if value.blank?
        return if value.match?(/\A(?:javascript|data|blob):/i)

        value = "https:#{value}" if value.start_with?("//")
        value = value.sub(/#\z/, "")
        return unless value.match?(/\Ahttps?:\/\//i)

        value
      end

      def extension_for(url)
        path = URI.parse(normalize_url(url).to_s).path.to_s
        ext = File.extname(path).delete(".").downcase
        ext.presence || (url.to_s.match?(%r{/pvid/}i) ? "pvid" : "unknown")
      rescue URI::InvalidURIError
        "unknown"
      end

      private

      def normalize_list(urls)
        urls.filter_map { |url| normalize_url(url) }
            .select { |url| classify(url) != :other }
            .uniq
      end

      def image_poster?(url)
        url.match?(/\.(jpe?g|png|gif|webp|avif|bmp)(?:\?|#|\z)/i)
      end

      def collect_urls(value, depth, nodes)
        return [] if value.blank? || depth > 8 || nodes > MAX_WALK_NODES

        case value
        when String
          [value]
        when Array
          value.each_with_object([]) do |item, acc|
            acc.concat(collect_urls(item, depth + 1, nodes + acc.size + 1))
          end
        when Hash
          collected = []
          URL_KEYS.each do |key|
            raw = value[key] || value[key.to_sym]
            collected.concat(collect_urls(raw, depth + 1, nodes + collected.size + 1)) if raw.present?
          end
          value.each_value do |item|
            next unless item.is_a?(Hash) || item.is_a?(Array) || item.is_a?(String)

            collected.concat(collect_urls(item, depth + 1, nodes + collected.size + 1))
          end
          collected
        else
          []
        end
      end
    end
  end
end
