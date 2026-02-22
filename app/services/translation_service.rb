# Сервис для перевода текстов
require 'httparty'

class TranslationService
  MYMEMORY_API_URL = 'https://api.mymemory.translated.net/get'
  INVALID_TRANSLATIONS = ['translatedText', 'PLEASE SELECT TWO DISTINCT LANGUAGES'].freeze
  
  # Универсальный метод перевода (для продуктов)
  # Использует каскад: MyMemory → LibreTranslate → Google Translate
  def self.translate(text, target_lang: 'ru', source_lang: 'pl', force: false, skip_mymemory: false, skip_google: false)
    return '' if text.blank?
    debug = ENV['TRANSLATION_DEBUG'].to_s == '1'
    
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
    
    # 1. MyMemory (если не отключен)
    unless skip_mymemory || ENV['MYMEMORY_DISABLED'].to_s == '1'
      begin
        translated = translate_with_my_memory(text, target_lang: target_lang, source_lang: source_lang, force: force)
        provider = 'mymemory' if translated.present? && !invalid_translation?(translated, text)
      rescue => e
        Rails.logger.warn("MyMemory failed: #{e.message}")
      end
    end

    # 2. LibreTranslate
    if translated.blank? || invalid_translation?(translated, text)
      begin
        translated = LibreTranslateService.translate(text, target_lang: target_lang, source_lang: source_lang)
        provider = 'libretranslate' if translated.present? && !invalid_translation?(translated, text)
      rescue => e2
        Rails.logger.warn("LibreTranslate failed: #{e2.message}")
      end
    end

    # 3. Google Translate (если настроен)
    if translated.blank? || invalid_translation?(translated, text)
      if skip_google
        Rails.logger.warn("Google Translate disabled, returning original text")
        translated = text
        provider = 'fallback'
      elsif ENV['GCLOUD_PROJECT'].present? && ENV['GOOGLE_APPLICATION_CREDENTIALS'].present?
        begin
          translated = GoogleTranslateService.translate(text, target_lang: target_lang)
          provider = 'google' if translated.present? && !invalid_translation?(translated, text)
        rescue => e3
          Rails.logger.error("All translation services failed: #{e3.message}")
          translated = text # Возвращаем оригинал
          provider = 'fallback'
        end
      else
        Rails.logger.warn("Google Translate not configured, returning original text")
        translated = text
        provider = 'fallback'
      end
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

