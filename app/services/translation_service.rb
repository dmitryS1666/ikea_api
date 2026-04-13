# Сервис для перевода текстов
require 'httparty'

class TranslationService
  MYMEMORY_API_URL = 'https://api.mymemory.translated.net/get'
  INVALID_TRANSLATIONS = ['translatedText', 'PLEASE SELECT TWO DISTINCT LANGUAGES'].freeze
  
  # Универсальный метод перевода (для продуктов)
  # Использует каскад: MyMemory → LibreTranslate → Google Translate
  def self.translate(text, target_lang: 'ru', source_lang: 'pl', force: false, skip_mymemory: false, skip_google: false, context: nil)
    return '' if text.blank?
    debug = ENV['TRANSLATION_DEBUG'].to_s == '1'
    
    context_info = context ? "[#{context}] " : ""
    
    # Кэширование переводов
    cached = TranslationCache.find_by(
      text: text.strip,
      target_language: target_lang,
      source_language: source_lang
    )
    if cached && !force
      return cached.translated_text unless invalid_translation?(cached.translated_text, text)
      cached.destroy
    end
    
    # Пробуем сервисы по очереди (только для товаров)
    translated = nil
    provider = nil
    
    # 0. AI Translation (OpenAI / DeepSeek)
    if translated.blank? || invalid_translation?(translated, text)
      begin
        Rails.logger.info("TranslationService: #{context_info}translating via AI: #{text.to_s.truncate(50)}")
        # По умолчанию используем OpenAI, так как ключ был передан
        translated = AiTranslationService.translate(text, target_lang: target_lang, source_lang: source_lang)
        provider = 'ai' if translated.present? && !invalid_translation?(translated, text)
      rescue => e_ai
        Rails.logger.warn("AI Translation failed: #{e_ai.message}")
      end
    end

    # 1. Google Translate (теперь первый приоритет)
    unless skip_google || ENV['GCLOUD_PROJECT'].blank? || ENV['GOOGLE_APPLICATION_CREDENTIALS'].blank?
      begin
        Rails.logger.info("TranslationService: #{context_info}translating via Google: #{text.to_s.truncate(50)}")
        translated = GoogleTranslateService.translate(text, target_lang: target_lang)
        provider = 'google' if translated.present? && !invalid_translation?(translated, text)
      rescue => e
        Rails.logger.warn("Google Translate failed: #{e.message}")
      end
    end

    # 2. MyMemory (если не отключен)
    if translated.blank? || invalid_translation?(translated, text)
      unless skip_mymemory || ENV['MYMEMORY_DISABLED'].to_s == '1'
        begin
          Rails.logger.info("TranslationService: #{context_info}translating via MyMemory: #{text.to_s.truncate(50)}")
          translated = translate_with_my_memory(text, target_lang: target_lang, source_lang: source_lang, force: force)
          provider = 'mymemory' if translated.present? && !invalid_translation?(translated, text)
        rescue => e2
          Rails.logger.warn("MyMemory failed: #{e2.message}")
        end
      end
    end

    # 3. LibreTranslate
    if translated.blank? || invalid_translation?(translated, text)
      begin
        Rails.logger.info("TranslationService: #{context_info}translating via LibreTranslate: #{text.to_s.truncate(50)}")
        translated = LibreTranslateService.translate(text, target_lang: target_lang, source_lang: source_lang)
        provider = 'libretranslate' if translated.present? && !invalid_translation?(translated, text)
      rescue => e3
        Rails.logger.warn("LibreTranslate failed: #{e3.message}")
      end
    end

    # 4. Fallback (оригинал)
    if translated.blank? || invalid_translation?(translated, text)
      Rails.logger.warn("All translation services failed, returning original text")
      translated = text
      provider = 'fallback'
    end

    if debug
      final_provider = provider || (translated.blank? || invalid_translation?(translated, text) ? 'fallback' : 'ok')
      Rails.logger.info("TranslationService: provider=#{final_provider} len=#{translated.to_s.length}")
    end
    
    # Сохраняем в кэш
    if translated.present? && !invalid_translation?(translated, text)
      begin
        cache = TranslationCache.find_or_initialize_by(
          text: text.strip,
          target_language: target_lang,
          source_language: source_lang
        )
        cache.translated_text = translated
        cache.save!
      rescue ActiveRecord::RecordInvalid => e
        # Уже есть в кэше или ошибка валидации, игнорируем
        Rails.logger.debug("Translation cache error: #{e.message}")
      end
    end
    
    translated
  end
  
  # Перевод только через MyMemory (для категорий)
  def self.translate_with_my_memory(text, target_lang: 'ru', source_lang: 'pl', force: false)
    return '' if text.blank?
    
    # Проверяем кэш
    cached = TranslationCache.find_by(
      text: text.strip,
      target_language: target_lang,
      source_language: source_lang
    )
    if cached && !force
      return cached.translated_text unless invalid_translation?(cached.translated_text, text)
      cached.destroy
    end
    
    email = ENV.fetch('MYMEMORY_EMAIL', 'translations@ikea-api.local')
    
    response = ProxyRotator.with_proxy_retry do |proxy_options|
      HTTParty.get(
        MYMEMORY_API_URL,
        query: {
          q: text.strip,
          langpair: "#{source_lang}|#{target_lang}",
          de: email
        },
        timeout: 10,
        **(proxy_options || {})
      )
    end
    
    if response.success?
      translated_text = response.dig('responseData', 'translatedText')
      if translated_text.present? && !invalid_translation?(translated_text, text)
        # Сохраняем в кэш
        begin
          cache = TranslationCache.find_or_initialize_by(
            text: text.strip,
            target_language: target_lang,
            source_language: source_lang
          )
          cache.translated_text = translated_text
          cache.save!
        rescue ActiveRecord::RecordInvalid => e
          # Уже есть в кэше или ошибка валидации, игнорируем
          Rails.logger.debug("Translation cache error: #{e.message}")
        end
        return translated_text
      end
    end
    
    raise "MyMemory translation failed: HTTP #{response.code}"
  rescue => e
    Rails.logger.warn("MyMemory translation error: #{e.message}")
    raise
  end

  def self.invalid_translation?(translated_text, original_text)
    return true if translated_text.blank?
    return true if INVALID_TRANSLATIONS.include?(translated_text.to_s.strip)
    return true if translated_text.to_s.strip == original_text.to_s.strip

    false
  end
end

