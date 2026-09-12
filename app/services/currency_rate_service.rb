# Сервис для получения курсов валют из ExchangeRate-API (база PLN)
require "net/http"
require "json"
require "uri"

class CurrencyRateService
  ER_API_URL = "https://open.er-api.com/v6/latest/PLN"
  TARGET_CODES = %w[USD EUR].freeze
  CURRENCY_NAMES = {
    "PLN" => "złoty polski",
    "USD" => "dolar amerykański",
    "EUR" => "euro"
  }.freeze

  def self.fetch_rates
    uri = URI(ER_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 10
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    request["Accept"] = "application/json"

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise StandardError, "ExchangeRate-API error: #{response.code} #{response.message}"
    end

    parse_rates(JSON.parse(response.body))
  rescue JSON::ParserError => e
    raise StandardError, "Failed to parse ExchangeRate-API response: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    raise StandardError, "ExchangeRate-API timeout: #{e.message}"
  end

  def self.format_rates_for_telegram(rates)
    return "Курсы валют не найдены" if rates.empty?

    filtered_rates = Array(rates[:rates]).select { |rate| TARGET_CODES.include?(rate[:code]) }
    filtered_rates << {
      currency: CURRENCY_NAMES["PLN"],
      code: "PLN",
      mid: 1.0
    }

    sorted_rates = filtered_rates.sort_by do |rate|
      case rate[:code]
      when "PLN" then 0
      when "USD" then 1
      when "EUR" then 2
      else 3
      end
    end

    byn_rates = rates[:byn_rates] || {}

    message = "💱 <b>Актуальные курсы валют (ExchangeRate-API)</b>\n\n"
    message += "Дата: #{rates[:effective_date]}\n"

    if sorted_rates.any?
      sorted_rates.each do |rate|
        emoji = case rate[:code]
                when "PLN" then "🇵🇱"
                when "USD" then "🇺🇸"
                when "EUR" then "🇪🇺"
                else "💱"
                end

        message += "#{emoji} <b>#{rate[:currency]}</b>\n"
        message += "   Код: #{rate[:code]}\n"
        if rate[:code] == "PLN"
          message += "   Курс: 1.0 PLN (базовая валюта)\n"
        else
          message += "   Курс: #{rate[:mid]} PLN\n"
        end
        message += "   Курс: #{format_byn_rate(byn_rates[rate[:code]])}\n\n"
      end
    else
      message += "Курсы валют не найдены"
    end

    message
  end

  private

  def self.parse_rates(data)
    raise StandardError, "ExchangeRate-API unsuccessful response" unless data["result"] == "success"

    raw = data["rates"] || {}
    missing = (%w[USD EUR BYN] - raw.keys)
    raise StandardError, "ExchangeRate-API missing rates: #{missing.join(', ')}" if missing.any?

    {
      rates: TARGET_CODES.map do |code|
        {
          currency: CURRENCY_NAMES[code],
          code: code,
          mid: invert_rate(raw[code])
        }
      end,
      effective_date: parse_update_date(data["time_last_update_utc"]),
      byn_rates: {
        "PLN" => raw["BYN"].to_f,
        "USD" => byn_per_unit(raw["BYN"], raw["USD"]),
        "EUR" => byn_per_unit(raw["BYN"], raw["EUR"])
      },
      source: "ExchangeRate-API"
    }
  end

  def self.invert_rate(units_per_pln)
    value = units_per_pln.to_f
    raise StandardError, "ExchangeRate-API returned a zero rate" if value.zero?

    (1.0 / value).round(4)
  end

  def self.byn_per_unit(byn_per_pln, units_per_pln)
    unit_rate = units_per_pln.to_f
    raise StandardError, "ExchangeRate-API returned a zero rate" if unit_rate.zero?

    byn_per_pln.to_f / unit_rate
  end

  def self.parse_update_date(value)
    return Date.current if value.blank?

    Time.parse(value.to_s).to_date.iso8601
  rescue ArgumentError
    Date.current.iso8601
  end

  def self.format_byn_rate(rate)
    return "н/д" if rate.nil?

    "#{rate.round(4)} BYN"
  end
end
