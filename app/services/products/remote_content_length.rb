# frozen_string_literal: true

require "net/http"
require "uri"

module Products
  # Размер удалённого файла без скачивания: HEAD, при необходимости Range GET.
  class RemoteContentLength
    MAX_REDIRECTS = 5
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15

    class << self
      def fetch(url)
        normalized = Products::VideoUrlExtractor.normalize_url(url)
        return if normalized.blank?

        ProxyRotator.with_proxy_retry do |proxy_options|
          request_length(URI.parse(normalized), proxy_options, MAX_REDIRECTS)
        end
      rescue URI::InvalidURIError => e
        Rails.logger.warn("RemoteContentLength: bad url #{url}: #{e.message}")
        nil
      rescue StandardError => e
        Rails.logger.warn("RemoteContentLength: #{url} failed: #{e.message}")
        nil
      end

      private

      def request_length(uri, proxy_options, redirects_left)
        http = build_http(uri, proxy_options)
        headers = default_headers

        head = Net::HTTP::Head.new(uri.request_uri, headers)
        response = http.request(head)

        if redirect?(response)
          return follow_redirect(uri, response, proxy_options, redirects_left)
        end

        if retryable_status?(response)
          raise StandardError, "HTTP #{response.code} for HEAD #{uri}"
        end

        length = parse_length(response)
        return length if length&.positive?

        range = Net::HTTP::Get.new(uri.request_uri, headers.merge("Range" => "bytes=0-0"))
        ranged = http.request(range)

        if redirect?(ranged)
          return follow_redirect(uri, ranged, proxy_options, redirects_left)
        end

        if retryable_status?(ranged)
          raise StandardError, "HTTP #{ranged.code} for Range #{uri}"
        end

        parse_length(ranged)
      end

      def follow_redirect(uri, response, proxy_options, redirects_left)
        raise StandardError, "Too many redirects for #{uri}" if redirects_left <= 0

        location = response["location"].to_s.strip
        raise StandardError, "Redirect without Location for #{uri}" if location.blank?

        next_uri = URI.join(uri.to_s, location)
        request_length(next_uri, proxy_options, redirects_left - 1)
      end

      def parse_length(response)
        range = response["content-range"].to_s
        if (match = range.match(%r{/\s*(\d+)\s*\z}))
          bytes = match[1].to_i
          return bytes if bytes.positive?
        end

        bytes = response["content-length"].to_i
        bytes.positive? ? bytes : nil
      end

      def redirect?(response)
        response.is_a?(Net::HTTPRedirection) || response.code.to_s.start_with?("3")
      end

      def retryable_status?(response)
        %w[403 407 429 500 502 503 504].include?(response.code.to_s)
      end

      def build_http(uri, proxy_options)
        http =
          if proxy_options && proxy_options[:http_proxyaddr]
            Net::HTTP.new(
              uri.host,
              uri.port,
              proxy_options[:http_proxyaddr],
              proxy_options[:http_proxyport],
              proxy_options[:http_proxyuser],
              proxy_options[:http_proxypass]
            )
          else
            Net::HTTP.new(uri.host, uri.port)
          end

        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http
      end

      def default_headers
        {
          "User-Agent" => ENV.fetch("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"),
          "Accept" => "*/*",
          "Accept-Language" => ENV.fetch("ACCEPT_LANGUAGE", "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7")
        }
      end
    end
  end
end
