# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module PolandTracks
  class Client
    ENDPOINT = "https://profile.shopbyshop.by/api/external/poland/ikea-tracks"
    RESPONSE_KEYS = %w[id code shop_number recipient_id cdek_number nomerikea].freeze
    class ConfigurationError < StandardError; end
    class Rejected < StandardError; end
    class Uncertain < StandardError; end

    def self.validate_config!
      raise ConfigurationError, "POLAND_TRACKS_API_KEY is missing" if ENV["POLAND_TRACKS_API_KEY"].blank?
    end

    def self.create!(payload)
      validate_config!
      uri = URI(ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{ENV.fetch('POLAND_TRACKS_API_KEY')}"
      request.body = JSON.generate(payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 20
      http.write_timeout = 10
      http.max_retries = 0
      response = http.request(request)
      status = response.code.to_i
      # Do not log/store arbitrary upstream bodies: they may echo passports or the key.
      raise Rejected, "HTTP #{status}" if [400, 401, 403, 404, 405, 422].include?(status)
      raise Uncertain, "HTTP #{status}; reconcile before retry" unless status == 201

      data = JSON.parse(response.body)
      validate_response!(data, payload)
      data.slice(*RESPONSE_KEYS)
    rescue ConfigurationError, Rejected, Uncertain
      raise
    rescue StandardError => e
      # Includes timeouts/EOF/invalid JSON after the remote server may have committed.
      raise Uncertain, "#{e.class.name}; reconcile before retry"
    end

    def self.validate_response!(data, payload)
      valid = data.is_a?(Hash) && (RESPONSE_KEYS - ["cdek_number"]).all? { |key| data[key].present? } &&
              data["id"].to_s.match?(/\A[1-9]\d*\z/) && data["recipient_id"].to_s.match?(/\A[1-9]\d*\z/) &&
              %w[code shop_number nomerikea].all? { |key| data[key].is_a?(String) } &&
              data["nomerikea"] == payload["nomerikea"] &&
              (payload["delivery_type"] == 5 ? (data["cdek_number"].nil? || data["cdek_number"].is_a?(String)) :
                (data["cdek_number"].is_a?(String) && data["cdek_number"].present? && data["cdek_number"] == payload["europost_track"]))
      raise Uncertain, "Invalid/mismatched 201 response; reconcile before retry" unless valid
      true
    end
  end
end
