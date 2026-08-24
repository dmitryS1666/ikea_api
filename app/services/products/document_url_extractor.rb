# frozen_string_literal: true

module Products
  # Собирает ссылки на инструкции/мануалы: manuals, assembly_documents, full_attributes, HTML PIP.
  class DocumentUrlExtractor
    FILE_EXT_RE = /\.(pdf|docx?|xlsx?|zip)(?:\?|#|\z)/i
    IKEA_DOC_PATH_RE = %r{(?:/assembly_instructions/|/manuals/|/product-support/|/files/pdf/)}i
    ABSOLUTE_URL_RE = %r{https?://[^\s"'<>\\]+}i
    RELATIVE_DOC_RE = %r{/(?:[a-z]{2}/[a-z]{2}/)?(?:assembly_instructions|manuals|files/pdf)/[^\s"'<>\\]+}i
    IMAGE_EXT_RE = /\.(jpe?g|png|gif|webp|avif|bmp|mp4|webm|mov|m4v)(?:\?|#|\z)/i
    LOCAL_PATH_RE = %r{\A/documents/}i
    URL_KEYS = %w[url src href link fileUrl file_url contentUrl content_url].freeze
    MAX_WALK_NODES = 2_000

    class << self
      def urls_from_product(product)
        urls = []
        urls.concat(urls_from_value(product.manuals))
        urls.concat(urls_from_value(product.assembly_documents))
        urls.concat(urls_from_value(product.full_attributes))
        normalize_list(urls)
      end

      def urls_from_html(html)
        text = html.to_s
        return [] if text.blank?

        urls = text.scan(ABSOLUTE_URL_RE)
        text.scan(RELATIVE_DOC_RE).each do |raw|
          urls << (raw.start_with?("http") ? raw : "https://www.ikea.com#{raw}")
        end
        normalize_list(urls)
      end

      def urls_from_value(value)
        normalize_list(collect_urls(value, 0, 0))
      end

      def downloadable?(url)
        classify(url) == :file
      end

      def classify(url)
        normalized = normalize_url(url)
        return :other if normalized.blank?
        return :file if document_file?(normalized)

        :other
      end

      def document_file?(url)
        return false if url.blank?
        return false if url.match?(IMAGE_EXT_RE)
        return true if url.match?(FILE_EXT_RE)
        return true if url.match?(IKEA_DOC_PATH_RE)

        false
      end

      def normalize_url(url)
        value = url.to_s.strip
        return if value.blank?
        return if value.match?(/\A(?:javascript|data|blob|mailto):/i)
        return if value.match?(LOCAL_PATH_RE)

        value = "https:#{value}" if value.start_with?("//")
        value = "https://www.ikea.com#{value}" if value.start_with?("/")
        Products::VideoUrlExtractor.normalize_url(value)
      end

      def canonical_key(url)
        PlDetailsFetcher.canonical_document_url_for_dedupe(normalize_url(url).to_s)
      end

      def extension_for(url)
        path = URI.parse(normalize_url(url).to_s).path.to_s
        ext = File.extname(path).delete(".").downcase
        return ext if ext.present?
        return "pdf" if url.to_s.match?(IKEA_DOC_PATH_RE)

        "unknown"
      rescue URI::InvalidURIError
        "unknown"
      end

      private

      def normalize_list(urls)
        urls.filter_map { |url| normalize_url(url) }
            .select { |url| classify(url) == :file }
            .uniq { |url| canonical_key(url) }
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
