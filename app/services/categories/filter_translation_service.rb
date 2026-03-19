module Categories
  class FilterTranslationService
    def self.run(category, force: false)
      new(category, force: force).execute
    end

    def initialize(category, force: false)
      @category = category
      @force = force
    end

    def execute
      return false if @category.available_filters.blank?
      
      # Если уже переведено и не принудительно, пропускаем
      return false if @category.available_filters_ru.present? && !@force

      translated_filters = @category.available_filters.map do |filter|
        translate_filter(filter)
      end

      if translated_filters.any?
        @category.update_columns(available_filters_ru: translated_filters)
        return true
      end

      false
    rescue => e
      Rails.logger.error("FilterTranslationService error for category #{@category.ikea_id}: #{e.message}")
      false
    end

    private

    def translate_filter(filter)
      new_filter = filter.dup
      
      # 1. Переводим название фильтра
      if filter["name"].present?
        new_filter["name"] = translate_text(filter["name"], context: "Category #{@category.ikea_id}, filter name: #{filter["parameter"]}")
      end

      # 2. Переводим значения фильтра
      if filter["values"].is_a?(Array)
        new_filter["values"] = filter["values"].map do |value|
          new_value = value.dup
          if value["name"].present?
            new_value["name"] = translate_text(value["name"], context: "Category #{@category.ikea_id}, filter value: #{value["id"]}")
          end
          new_value
        end
      end

      new_filter
    end

    def translate_text(text, context: nil)
      return text if text.blank?
      
      # Используем Google Translate, как запрошено
      # skip_mymemory: true принуждает использовать Google или LibreTranslate
      # Но в TranslationService.translate Google идет первым
      translated = TranslationService.translate(
        text, 
        target_lang: 'ru', 
        source_lang: 'pl', 
        force: @force,
        skip_mymemory: true,
        context: context
      )

      # Если перевод не удался или вернул оригинал, пробуем напрямую через GoogleTranslateService
      # на случай если TranslationService решил пропустить Google
      if translated.blank? || TranslationService.invalid_translation?(translated, text)
        begin
          translated = GoogleTranslateService.translate(text, target_lang: 'ru')
        rescue => e
          Rails.logger.warn("Direct Google Translate failed: #{e.message}")
        end
      end

      translated.presence || text
    end
  end
end
