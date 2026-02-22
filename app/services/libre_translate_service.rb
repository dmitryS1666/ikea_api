# Сервис для перевода через LibreTranslate
require 'httparty'

class LibreTranslateService
  SERVERS = [
    'https://libretranslate.de/translate',
    'https://libretranslate.com/translate'
  ].freeze
  
  def self.translate(text, target_lang: 'ru', source_lang: 'pl')
    return '' if text.blank?
    debug = ENV['TRANSLATION_DEBUG'].to_s == '1'
    
    SERVERS.each do |server_url|
      ProxyRotator.with_proxy_retry do |proxy_options|
        begin
          response = HTTParty.post(
            server_url,
            body: {
              q: text.strip,
              source: source_lang,
              target: target_lang,
              format: 'text'
            }.to_json,
            headers: { 
              'Content-Type' => 'application/json',
              'User-Agent' => ENV.fetch('USER_AGENT', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
            },
            timeout: 10,
            **(proxy_options || {})
          )
          
          if response.success?
            translated_text = response['translatedText']
            return translated_text if translated_text.present?
          else
            if debug
              Rails.logger.warn("LibreTranslate response status=#{response.code} body=#{response.body.to_s[0, 500]}")
            end
          end
        rescue => e
          Rails.logger.warn("LibreTranslate server #{server_url} failed: #{e.message}")
          next
        end
      end
    end
    
    raise "All LibreTranslate servers failed"
  end
end

