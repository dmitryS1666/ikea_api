# frozen_string_literal: true

require 'httparty'

class AiTranslationService
  include HTTParty

  OPENAI_URL = 'https://api.openai.com/v1/chat/completions'
  DEEPSEEK_URL = 'https://api.deepseek.com/chat/completions'

  def self.translate(text, target_lang: 'ru', source_lang: 'pl', provider: :openai)
    new(provider).translate(text, target_lang: target_lang, source_lang: source_lang)
  end

  def initialize(provider = :openai)
    @provider = provider.to_sym
    setup_provider
  end

  def translate(text, target_lang: 'ru', source_lang: 'pl')
    return '' if text.blank?

    options = {
      headers: {
        'Authorization' => "Bearer #{@api_key}",
        'Content-Type' => 'application/json'
      },
      body: {
        model: @model,
        messages: [
          { role: 'system', content: system_prompt(target_lang, source_lang) },
          { role: 'user', content: text }
        ],
        temperature: 0.3
      }.to_json,
      timeout: 30
    }

    # Используем прокси для OpenAI, если они настроены
    if @provider == :openai && defined?(ProxyRotator)
      begin
        response = ProxyRotator.with_proxy_retry do |proxy_options|
          # Передаем параметры по отдельности, чтобы избежать вложенности
          HTTParty.post(@api_url, {
            headers: options[:headers],
            body: options[:body],
            timeout: options[:timeout]
          }.merge(proxy_options || {}))
        end
      rescue => e
        Rails.logger.error("AI Translation Proxy Error (#{@provider}): #{e.message}")
        nil
      end
    else
      response = self.class.post(@api_url, options)
    end

    if response&.success?
      response.dig('choices', 0, 'message', 'content')&.strip
    else
      code = response&.code || 'No Response'
      body = response&.body || 'Empty Body'
      Rails.logger.error("AI Translation Error (#{@provider}): #{code} - #{body}")
      nil
    end
  rescue => e
    Rails.logger.error("AI Translation Exception (#{@provider}): #{e.message}")
    nil
  end

  private

  def setup_provider
    case @provider
    when :openai
      @api_key = ENV['OPENAI_API_KEY']
      @api_url = OPENAI_URL
      @model = ENV.fetch('OPENAI_MODEL', 'gpt-4o-mini')
    when :deepseek
      @api_key = ENV['DEEPSEEK_API_KEY']
      @api_url = DEEPSEEK_URL
      @model = 'deepseek-chat'
    else
      raise "Unknown AI provider: #{@provider}"
    end

    raise "API Key for #{@provider} is not configured" if @api_key.blank?
  end

  def system_prompt(target_lang, source_lang)
    "You are a professional translator. Translate the following product description from #{source_lang} to #{target_lang}. " \
    "Maintain the original formatting and technical terms where appropriate. Return only the translated text."
  end
end
