# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"

class EuropostApiService
  # Legacy JSON-RPC-style endpoint (GetJWT, Postal.*). Not the REST v1.8.0 base URL.
  BASE_URL = ENV.fetch("EUROPOST_BASE_URL", "https://api.eurotorg.by:10352/Json")

  DEFAULT_REST_API_BASE_URL = "https://api-kassa.evropochta.by"

  class Error < StandardError; end
  class ValidationError < Error; end
  class HttpError < Error; end
  class UnauthorizedError < HttpError; end
  class ResponseError < Error; end
  class NonJsonResponseError < ResponseError; end

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
    Rails.logger.debug("[EUROPOST] OfficesOut raw response: \#{res.inspect}")
    table = res["Table"]
    return [] unless table.is_a?(Array)

    if table.first.is_a?(Hash) && table.first["Error"]
      Rails.logger.error("[EUROPOST] Postal.OfficesOut error=#{table.first["Error"]} desc=#{table.first["ErrorDescription"]}")
      return []
    end

    table
  end

  # GET /api/external/stores — список ПВЗ/ОПС (авторизация: Header Token).
  # При отсутствии EUROPOST_API_TOKEN возвращает пустой массив (без сетевых вызовов).
  def self.external_stores(type: nil)
    token = ENV["EUROPOST_API_TOKEN"].to_s.strip
    return [] if token.blank?

    query = {}
    t = normalize_external_store_type(type)
    query["type"] = t if t

    parsed = get_external_json_with_token!("/api/external/stores", query: query, token: token)
    extract_external_stores_array(parsed)
  rescue UnauthorizedError => e
    Rails.logger.error("[EUROPOST] external/stores unauthorized #{e.class}: #{e.message}")
    []
  rescue HttpError, ResponseError, NonJsonResponseError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error("[EUROPOST] external/stores failed #{e.class}: #{e.message}")
    []
  end

  # Для сопоставления с Postal.OfficesOut: если type не задан, запрашиваем ОПС/склад/ОПС при складе отдельно
  # и объединяем по id (часто один вызов без type не возвращает все точки).
  STORE_TYPES_FOR_UNION = [1, 3, 4].freeze

  def self.external_stores_for_merge(type: nil)
    t = normalize_external_store_type(type)
    return external_stores(type: t) if t

    by_id = {}
    STORE_TYPES_FOR_UNION.each do |store_type|
      external_stores(type: store_type).each do |row|
        next unless row.is_a?(Hash)

        sid = row["id"] || row[:id]
        next if sid.blank?

        key = sid.to_s
        existing = by_id[key]
        by_id[key] = merge_richer_store_row(existing, row)
      end
    end
    by_id.values
  end

  def self.merge_richer_store_row(existing, candidate)
    return candidate if existing.nil?

    store_enrichment_score(candidate) >= store_enrichment_score(existing) ? candidate : existing
  end
  private_class_method :merge_richer_store_row

  def self.store_enrichment_score(row)
    score = 0
    sched = row["schedules"] || row[:schedules]
    score += 4 if sched.is_a?(Array) && sched.any?
    score += 2 if (row["working_hours"] || row[:working_hours]).to_s.strip.present?
    score += 1 if (row["break_hours"] || row[:break_hours]).to_s.strip.present?
    score
  end
  private_class_method :store_enrichment_score

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

  # API v1.8.0
  # POST /api/external/postal/create
  # New optional fields:
  # - is_relabeling
  # - is_oversize
  # - is_completeness_check
  # - packing_payer
  # - shipment_payer
  def self.postal_create(data:)
    validate_postal_create_data!(data)
    post_external_json!("/api/external/postal/create", data)
  end

  # API v1.8.0
  # POST /api/external/postal/payment/calculate
  def self.postal_payment_calculate(data:)
    validate_hash_payload!(data, context: "postal_payment_calculate")
    post_external_json!("/api/external/postal/payment/calculate", data)
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
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if uri.scheme == "https"

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json; charset=utf-8"
    req["Accept"] = "application/json"
    req.body = JSON.generate(payload)

    res = http.request(req)
    body = read_response_body_utf8(res)

    JSON.parse(body)
  end
  private_class_method :post_json!

  # Допустимые значения query `type` для GET /api/external/stores (1 — ОПС, 3 — склад, 4 — ОПС при складе).
  def self.external_stores_type_param(value)
    normalize_external_store_type(value)
  end

  def self.normalize_external_store_type(type)
    v = type.to_s.strip
    return nil if v.blank?

    return v.to_i if %w[1 3 4].include?(v)

    nil
  end
  private_class_method :normalize_external_store_type

  def self.extract_external_stores_array(parsed)
    case parsed
    when Array
      return parsed
    when Hash
      %w[data stores results items offices rows Table].each do |key|
        v = parsed[key] || parsed[key.to_sym]
        return v if v.is_a?(Array)
      end

      nested = parsed["data"] || parsed[:data]
      if nested.is_a?(Array)
        return nested
      elsif nested.is_a?(Hash)
        inner = nested["stores"] || nested[:stores] || nested["items"] || nested[:items]
        return inner if inner.is_a?(Array)
      end
    end

    []
  end
  private_class_method :extract_external_stores_array

  # REST API v1.8.0 (external). Base URL without trailing slash.
  def self.rest_api_base_url
    ENV["EUROPOST_API_BASE_URL"].to_s.strip.chomp("/").presence || DEFAULT_REST_API_BASE_URL
  end

  def self.external_rest_token!
    token = ENV["EUROPOST_API_TOKEN"].to_s.strip
    raise ValidationError, "EUROPOST_API_TOKEN is required for Europost REST API calls" if token.blank?

    token
  end
  private_class_method :external_rest_token!

  def self.external_request_uri(path, query = nil)
    path_clean = path.sub(%r{\A/}, "")
    uri = URI.join("#{rest_api_base_url}/", path_clean)
    uri.query = URI.encode_www_form(query) if query.present? && query.any?
    uri
  end
  private_class_method :external_request_uri

  def self.configure_external_http!(http)
    open_t = ENV["EUROPOST_HTTP_OPEN_TIMEOUT"].presence || ENV["EUROPOST_OPEN_TIMEOUT"].presence || "15"
    read_t = ENV["EUROPOST_HTTP_READ_TIMEOUT"].presence || ENV["EUROPOST_READ_TIMEOUT"].presence || "60"
    http.open_timeout = Integer(open_t)
    http.read_timeout = Integer(read_t)
  end
  private_class_method :configure_external_http!

  def self.json_content_type?(header_value)
    v = header_value.to_s.downcase
    return false if v.blank?

    v.include?("application/json") || v.include?("+json")
  end
  private_class_method :json_content_type?

  def self.assert_external_json_body!(response, body)
    if body.lstrip.start_with?("<")
      raise NonJsonResponseError, "Europost API returned non-JSON response. Check EUROPOST_API_BASE_URL"
    end

    unless json_content_type?(response["Content-Type"])
      raise NonJsonResponseError, "Europost API returned non-JSON response. Check EUROPOST_API_BASE_URL"
    end

    parsed = JSON.parse(body)
    parsed
  rescue JSON::ParserError
    raise NonJsonResponseError, "Europost API returned non-JSON response. Check EUROPOST_API_BASE_URL"
  end
  private_class_method :assert_external_json_body!

  def self.raise_for_external_http_status!(response, body)
    case response
    when Net::HTTPUnauthorized
      raise UnauthorizedError, "Europost API authorization failed (HTTP 401). Check EUROPOST_API_TOKEN."
    end

    return if response.is_a?(Net::HTTPSuccess)

    snippet = body.to_s[0, 400]
    raise HttpError, "HTTP #{response.code}: #{snippet.presence || response.message}"
  end
  private_class_method :raise_for_external_http_status!

  def self.read_response_body_utf8(response)
    raw = response.body.to_s
    (+raw).force_encoding(Encoding::UTF_8).sub(/\A\xEF\xBB\xBF/, "")
  end
  private_class_method :read_response_body_utf8

  def self.get_external_json_with_token!(path, query:, token:)
    uri = external_request_uri(path, query)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if uri.scheme == "https"
    configure_external_http!(http)

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "application/json"
    req["Token"] = token

    res = http.request(req)
    body = read_response_body_utf8(res)

    raise_for_external_http_status!(res, body)
    parsed = assert_external_json_body!(res, body)
    raise ResponseError, "Expected JSON array or object response, got: #{parsed.class}" unless parsed.is_a?(Hash) || parsed.is_a?(Array)

    parsed
  end
  private_class_method :get_external_json_with_token!

  def self.post_external_json!(path, payload)
    token = external_rest_token!
    uri = external_request_uri(path, nil)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if uri.scheme == "https"
    configure_external_http!(http)

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json; charset=utf-8"
    req["Accept"] = "application/json"
    req["Token"] = token
    req.body = JSON.generate(payload)

    res = http.request(req)
    body = read_response_body_utf8(res)

    raise_for_external_http_status!(res, body)
    parsed = assert_external_json_body!(res, body)
    raise ResponseError, "Expected JSON object response, got: #{parsed.class}" unless parsed.is_a?(Hash)

    if parsed["error"].present?
      raise ResponseError, parsed["error"].to_s
    end

    parsed
  end
  private_class_method :post_external_json!

  def self.validate_postal_create_data!(data)
    validate_hash_payload!(data, context: "postal_create")

    validate_optional_boolean!(data, "is_relabeling")
    validate_optional_boolean!(data, "is_oversize")
    validate_optional_boolean!(data, "is_completeness_check")
    validate_optional_payer!(data, "packing_payer")
    validate_optional_payer!(data, "shipment_payer")
  end
  private_class_method :validate_postal_create_data!

  def self.validate_hash_payload!(payload, context:)
    return if payload.is_a?(Hash)

    raise ValidationError, "#{context} expects Hash payload"
  end
  private_class_method :validate_hash_payload!

  def self.validate_optional_boolean!(payload, key)
    return unless payload.key?(key)

    value = payload[key]
    return if [true, false, 1, 0, "1", "0", "true", "false"].include?(value)

    raise ValidationError, "#{key} must be boolean-like"
  end
  private_class_method :validate_optional_boolean!

  def self.validate_optional_payer!(payload, key)
    return unless payload.key?(key)

    value = payload[key]
    valid_values = [0, 1, "0", "1"]
    return if valid_values.include?(value)

    raise ValidationError, "#{key} must be 0 (sender) or 1 (recipient)"
  end
  private_class_method :validate_optional_payer!
end
