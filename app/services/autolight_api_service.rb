# frozen_string_literal: true

require "net/http"
require "json"

class AutolightApiService
  BASE_URL = ENV.fetch("AUTOLIGHT_BASE_URL", "http://api.autolight.by/v1")
  API_KEY = ENV.fetch("AUTOLIGHT_API_KEY", "test_key")

  def self.get_cities_list
    get_json!("getCitiesList")
  end

  def self.get_post_offices_list
    get_json!("getPostOfficesList")
  end

  def self.get_tracking(order_number:)
    get_json!("getTracking", { orderNumber: order_number })
  end

  def self.get_order_status(order_number:)
    get_json!("getOrderStatus", { orderNumber: order_number })
  end

  # -----------------
  # internal
  # -----------------

  def self.get_json!(operation, params = {})
    uri = URI("#{BASE_URL}/#{operation}/")
    query_params = { apikey: API_KEY, testmode: "yes" }.merge(params)
    uri.query = URI.encode_www_form(query_params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "application/json"

    res = http.request(req)
    
    unless res.is_a?(Net::HTTPSuccess)
      Rails.logger.error("[AUTOLIGHT] HTTP error: #{res.code} #{res.message}")
      return { "resultCode" => 255, "messages" => ["HTTP Error: #{res.code}"] }
    end

    body = res.body.to_s.force_encoding("UTF-8").sub("\xEF\xBB\xBF", "")
    JSON.parse(body)
  rescue StandardError => e
    Rails.logger.error("[AUTOLIGHT] Exception: #{e.message}")
    { "resultCode" => 255, "messages" => [e.message] }
  end
  private_class_method :get_json!

  def self.post_json!(operation, payload = {})
    uri = URI("#{BASE_URL}/#{operation}/")
    uri.query = URI.encode_www_form({ apikey: API_KEY, testmode: "yes" })

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json; charset=utf-8"
    req["Accept"] = "application/json"
    req.body = JSON.generate(payload)

    res = http.request(req)
    
    unless res.is_a?(Net::HTTPSuccess)
      Rails.logger.error("[AUTOLIGHT] HTTP error: #{res.code} #{res.message}")
      return { "resultCode" => 255, "messages" => ["HTTP Error: #{res.code}"] }
    end

    body = res.body.to_s.force_encoding("UTF-8").sub("\xEF\xBB\xBF", "")
    JSON.parse(body)
  rescue StandardError => e
    Rails.logger.error("[AUTOLIGHT] Exception: #{e.message}")
    { "resultCode" => 255, "messages" => [e.message] }
  end
  private_class_method :post_json!
end
