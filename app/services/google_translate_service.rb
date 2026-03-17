require 'google/cloud/translate'

# Сервис для перевода через Google Cloud Translate
# Требует настройки: GCLOUD_PROJECT и GOOGLE_APPLICATION_CREDENTIALS
class GoogleTranslateService
  def self.client
    @client ||= Google::Cloud::Translate.new(version: :v2)
  end

  def self.translate(text, target_lang: 'ru')
    return '' if text.blank?
    
    unless ENV['GCLOUD_PROJECT'].present? && ENV['GOOGLE_APPLICATION_CREDENTIALS'].present?
      raise "Google Cloud Translate not configured"
    end
    
    # Handle both single string and array of strings
    translation = client.translate(
      text,
      to: target_lang
    )
    
    if text.is_a?(Array)
      translation.map(&:text)
    else
      translation.text
    end
  rescue => e
    Rails.logger.error("Google Translate error: #{e.message}")
    raise
  end
end

