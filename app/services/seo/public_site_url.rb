# frozen_string_literal: true

module Seo
  # Публичный адрес витрины для ссылок, которые видят покупатели и поисковые роботы.
  # Домен и протокол берутся только из PUBLIC_SITE_URL. Host и X-Forwarded-Host
  # не используются: внутренний адрес приложения (docker, localhost, IP) не должен
  # попадать в микроразметку и другие публичные ссылки.
  module PublicSiteUrl
    DEFAULT = "https://ikeya.by"

    module_function

    def resolve(_request = nil)
      configured_origin || DEFAULT
    end

    # Оставляет уже публичный https-адрес. Внутренний или непроверенный адрес
    # заменяет на адрес витрины из конфигурации.
    def coerce(candidate)
      trusted = trusted_origin(candidate)
      return trusted if trusted

      resolve
    end

    def configured_origin
      trusted_origin(ENV["PUBLIC_SITE_URL"])
    end

    def trusted_origin(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      uri = URI.parse(raw)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return nil if internal_host?(uri.host)

      port = uri.port
      port_suffix = port && port != 443 ? ":#{port}" : ""
      "https://#{uri.host.downcase}#{port_suffix}"
    rescue URI::InvalidURIError
      nil
    end

    def internal_host?(host)
      normalized = host.to_s.downcase
      return true if normalized.blank?
      return true if normalized == "localhost"
      return true if normalized == "host.docker.internal"
      return true if normalized.end_with?(".localhost", ".local", ".internal")
      return true if normalized.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)

      false
    end
  end
end
