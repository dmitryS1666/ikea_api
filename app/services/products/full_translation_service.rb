module Products
  class FullTranslationService
    def self.run(product, force: true)
      new(product, force: force).execute
    end

    def initialize(product, force: true)
      @product = product
      @force = force
    end

    def execute
      updates = {}
      
      # 1. Translate name
      if @product.name.present?
        translated_name = translate_text(@product.name, context: "Product SKU: #{@product.sku}, field: name")
        if translated_name.present? && !TranslationService.invalid_translation?(translated_name, @product.name)
          updates[:name_ru] = translated_name
        end
      end

      # 2. Translate full_attributes
      # ЗАЩИТА: Используем ТОЛЬКО оригинальные атрибуты. Никогда не переводим уже переведенное.
      source_attrs = @product.full_attributes.presence
      if source_attrs.present?
        translated_attrs = translate_hash(source_attrs, context: "Product SKU: #{@product.sku}, full_attributes")
        
        # ЗАЩИТА: Проверяем, что мы не получили пустой или деградировавший объект
        if should_update_attributes?(source_attrs, translated_attrs)
          updates[:full_attributes_ru] = translated_attrs
        else
          Rails.logger.warn("FullTranslationService: Translation for #{@product.sku} seems invalid or incomplete, skipping update")
        end
      end

      # Update the product if there are changes
      if updates.any?
        @product.update_columns(updates)
        return true
      end

      false
    rescue => e
      Rails.logger.error("FullTranslationService error for product #{@product.sku}: #{e.message}")
      false
    end

    private

    def should_update_attributes?(source, translated)
      return false if translated.blank?
      return false unless translated.is_a?(Hash)
      
      # Если в оригинале были ключи, а в переводе их стало 0 — это ошибка
      return false if source.is_a?(Hash) && source.keys.any? && translated.keys.empty?
      
      # Если количество ключей в верхнем уровне уменьшилось более чем на 50% — подозрительно
      if source.is_a?(Hash) && source.size > 2
        return false if translated.size < (source.size / 2.0)
      end

      # Проверяем, что это не просто копия оригинала (если перевод не сработал совсем)
      return false if translated == @product.full_attributes_ru && !@force

      true
    end

    def translate_hash(hash, context: nil)
      return hash unless hash.is_a?(Hash)

      new_hash = {}
      hash.each do |key, value|
        # Translate key if it's a string and looks like Polish
        new_key = translate_key(key, context: "#{context} key")
        new_key = key if new_key.blank? # Защита: оставляем оригинал ключа если перевод пустой
        
        # Recursively translate value
        new_value = case value
                   when Hash
                     translate_hash(value, context: "#{context} > #{key}")
                   when Array
                     value.map { |v| v.is_a?(Hash) ? translate_hash(v, context: "#{context} > #{key}[]") : translate_value(v, context: "#{context} > #{key}[]") }
                   else
                     translate_value(value, context: "#{context} > #{key}")
                   end
        
        new_hash[new_key] = new_value
      end
      new_hash
    end

    def translate_key(key, context: nil)
      return key unless key.is_a?(String)
      return key if key.blank? || !contains_polish?(key)
      
      # Skip common English keys that are already standard
      return key if common_english_key?(key)
      
      translate_text(key, context: context)
    end

    def common_english_key?(key)
      @common_english_keys ||= %w[
        sku url link count width height length weight depth 
        packaging details size description instructions files 
        title name type id status created_at updated_at
        short_description local_url details
      ].freeze
      @common_english_keys.include?(key.to_s.downcase)
    end

    def translate_value(value, context: nil)
      return value unless value.is_a?(String)
      return value if value.blank? || !contains_polish?(value)
      
      # Skip if it's just numbers and units (like "200 cm")
      return value if is_dimension_value?(value)
      
      translate_text(value, context: context)
    end

    def translate_text(text, context: nil)
      return text if text.blank?
      
      # We force Google Translate as requested
      TranslationService.translate(
        text, 
        target_lang: 'ru', 
        source_lang: 'pl', 
        force: @force, 
        skip_mymemory: true, # Prioritize Google
        skip_google: false,
        context: context
      )
    end

    def contains_polish?(text)
      # Simple check: does it have Polish characters?
      # Polish chars: ą, ć, ę, ł, ń, ó, ś, ź, ż
      text.to_s.match?(/[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]/) || !text.to_s.match?(/[А-Яа-яЁё]/)
    end

    def is_dimension_value?(text)
      # Check if it's just a number with units (cm, mm, kg, etc.)
      text.to_s.strip.match?(/\A[\d\s.,xх×\-\+%]*(cm|mm|kg|g|l|м|м2|m2|m3|%)?[\d\s.,xх×\-\+%]*\z/i)
    end
  end
end
