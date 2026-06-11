# frozen_string_literal: true

require "net/http"
require "json"

module SeoCatalogPages
  class RevalidateFrontendService
    DEFAULT_TIMEOUT = 5

    def self.call(paths:)
      new(paths: paths).call
    end

    def initialize(paths:)
      @paths = Array(paths).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def call
      return skipped(:no_paths) if paths.empty?
      return skipped(:no_url) if revalidate_url.blank?

      uri = URI.parse(revalidate_url)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = {
        secret: ENV["FRONTEND_REVALIDATE_SECRET"].to_s,
        paths: paths
      }.to_json

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: timeout,
        read_timeout: timeout
      ) { |http| http.request(request) }

      ok = response.code.to_i.between?(200, 299)
      Rails.logger.public_send(
        ok ? :info : :warn,
        "SeoCatalogPages::RevalidateFrontendService paths=#{paths.join(',')} status=#{response.code}"
      )

      { ok: ok, status: response.code.to_i, body: response.body.to_s }
    rescue StandardError => e
      Rails.logger.warn("SeoCatalogPages::RevalidateFrontendService failed: #{e.class}: #{e.message}")
      { ok: false, error: e.message }
    end

    private

    attr_reader :paths

    def revalidate_url
      ENV["FRONTEND_REVALIDATE_URL"].to_s.strip
    end

    def timeout
      ENV.fetch("FRONTEND_REVALIDATE_TIMEOUT", DEFAULT_TIMEOUT).to_i
    rescue StandardError
      DEFAULT_TIMEOUT
    end

    def skipped(reason)
      Rails.logger.info("SeoCatalogPages::RevalidateFrontendService skipped: #{reason}")
      { ok: true, skipped: reason }
    end
  end
end
