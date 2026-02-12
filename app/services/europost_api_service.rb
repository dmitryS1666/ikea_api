# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"

class EuropostApiService
  BASE_URL = ENV.fetch("EUROPOST_BASE_URL", "https://api.eurotorg.by:10352/Json")

  def self.get_jwt!
    payload = {
      "CRC" => "",
      "Packet" => {
        "JWT" => "null",
        "MethodName" => "GetJWT",
        "ServiceNumber" => ENV.fetch("EUROPOST_SERVICE_NUMBER"),
        "Data" => {
          "LoginName" => ENV.fetch("EUROPOST_LOGIN"),
          "Password" => ENV.fetch("EUROPOST_PASSWORD"),
          "LoginNameTypeId" => ENV.fetch("EUROPOST_LOGIN_TYPE_ID", "1").to_i
        }
      }
    }

    res = post_json!(payload)
    table = res["Table"]
    raise "No Table in GetJWT response: #{res.inspect}" unless table.is_a?(Array) && table.first

    row0 = table.first
    if row0["Error"]
      raise "GetJWT error #{row0["Error"]}: #{row0["ErrorDescription"]}"
    end

    jwt = row0["JWT"].to_s
    raise "Empty JWT in response: #{row0.inspect}" if jwt.empty?

    jwt
  end

  def self.jwt
    @jwt ||= get_jwt!
  end

  def self.postal_tracking(number:)
    payload = packet_payload(
      method_name: "Postal.Tracking",
      data: {
        "Number" => number.to_s
      }
    )

    res = post_json!(payload)
    table = res["Table"]
    return [] unless table.is_a?(Array)

    if table.first.is_a?(Hash) && table.first["Error"]
      Rails.logger.error("[EUROPOST] Postal.Tracking error=#{table.first["Error"]} desc=#{table.first["ErrorDescription"]}")
      return []
    end

    table
  end

  def self.offices_out
    payload = packet_payload(
      method_name: "Postal.OfficesOut",
      data: {}
    )

    res = post_json!(payload)
    table = res["Table"]
    return [] unless table.is_a?(Array)

    if table.first.is_a?(Hash) && table.first["Error"]
      Rails.logger.error("[EUROPOST] Postal.OfficesOut error=#{table.first["Error"]} desc=#{table.first["ErrorDescription"]}")
      return []
    end

    table
  end

  def self.offices_in(type_sender: nil)
    data = {}
    data["TypeSender"] = type_sender if type_sender

    payload = packet_payload(
      method_name: "Postal.OfficesIn",
      data: data
    )

    res = post_json!(payload)
    table = res["Table"]
    return [] unless table.is_a?(Array)

    if table.first.is_a?(Hash) && table.first["Error"]
      Rails.logger.error("[EUROPOST] Postal.OfficesIn error=#{table.first["Error"]} desc=#{table.first["ErrorDescription"]}")
      return []
    end

    table
  end

  # -----------------
  # internal
  # -----------------

  def self.packet_payload(method_name:, data:)
    {
      "CRC" => "",
      "Packet" => {
        "JWT" => jwt,
        "MethodName" => method_name,
        "ServiceNumber" => ENV.fetch("EUROPOST_SERVICE_NUMBER"),
        "Data" => data
      }
    }
  end
  private_class_method :packet_payload

  def self.post_json!(payload)
    uri = URI(BASE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json; charset=utf-8"
    req["Accept"] = "application/json"
    req.body = JSON.generate(payload)

    res = http.request(req)
    body = res.body.to_s.force_encoding("UTF-8").sub("\xEF\xBB\xBF", "")

    JSON.parse(body)
  end
  private_class_method :post_json!
end
