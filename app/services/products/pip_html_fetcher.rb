# frozen_string_literal: true

require "net/http"
require "uri"

module Products
  # Лёгкий GET HTML страницы товара IKEA (без headless / scrape.do).
  class PipHtmlFetcher
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 30

    class << self
      def fetch(url)
        full_url = url.to_s.start_with?("http") ? url.to_s : "https://www.ikea.com#{url}"
        uri = URI.parse(full_url)

        fetch_uri(uri, redirects_left: 5)
      rescue URI::InvalidURIError => e
        Rails.logger.warn("PipHtmlFetcher: bad url #{url}: #{e.message}")
        nil
      rescue StandardError => e
        Rails.logger.warn("PipHtmlFetcher: #{url} failed: #{e.message}")
        nil
      end

      private

      def fetch_uri(uri, redirects_left:)
        ProxyRotator.with_proxy_retry do |proxy_options|
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

          request = Net::HTTP::Get.new(uri.request_uri, headers)
          response = http.request(request)

          if response.is_a?(Net::HTTPRedirection)
            raise StandardError, "Too many redirects for #{uri}" if redirects_left <= 0

            location = response["location"].to_s.strip
            raise StandardError, "Redirect without Location for #{uri}" if location.blank?

            return fetch_uri(URI.join(uri.to_s, location), redirects_left: redirects_left - 1)
          end

          if %w[403 407 429 500 502 503 504].include?(response.code.to_s)
            raise StandardError, "HTTP #{response.code} for #{uri}"
          end

          return unless response.is_a?(Net::HTTPSuccess)

          response.body
        end
      end

      def headers
        {
          "User-Agent" => ENV.fetch("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"),
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language" => ENV.fetch("ACCEPT_LANGUAGE", "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7,ru;q=0.6")
        }
      end
    end
  end
end
