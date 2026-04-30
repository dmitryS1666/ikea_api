module Sendpulse
  class Client
    include HTTParty

    DEFAULT_BASE_URL = "https://api.sendpulse.com".freeze

    def initialize(api_key: ENV["SENDPULSE_API_KEY"], base_url: ENV["SENDPULSE_API_BASE_URL"])
      @api_key = api_key
      @base_url = (base_url.presence || DEFAULT_BASE_URL).to_s
    end

    def get(path, params = {})
      response = self.class.get(url_for(path), headers: headers, query: params)
      parse_response(response, endpoint: path)
    end

    def post(path, payload = {})
      response = self.class.post(url_for(path), headers: headers, body: payload.to_json)
      parse_response(response, endpoint: path)
    end

    private

    def headers
      {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json"
      }
    end

    def url_for(path)
      "#{@base_url}#{path.start_with?("/") ? path : "/#{path}"}"
    end

    def parse_response(response, endpoint:)
      body = parse_body(response.body)
      return body if response.success?

      Rails.logger.error(
        "[SendPulse] Request failed status=#{response.code} endpoint=#{endpoint} body=#{safe_log_body(body)}"
      )
      raise Sendpulse::Error.new(
        message: "SendPulse request failed",
        status: response.code,
        response_body: body,
        endpoint: endpoint
      )
    end

    def parse_body(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      { "raw_body" => body.to_s }
    end

    def safe_log_body(body)
      body.is_a?(String) ? body : body.to_json
    rescue StandardError
      body.to_s
    end
  end
end
