class ProductTranslationRepairService
  FIELDS_TO_FIX = %w[
    name_ru content_ru material_info_ru good_info_ru materials_ru features_ru
    care_instructions_ru environmental_info_ru short_description_ru designer_ru
    safety_info_ru good_to_know_ru dimensions_ru
  ].freeze

  def self.run(limit: nil)
    # Ищем продукты, где хотя бы в одном из полей есть "translatedText"
    query_parts = FIELDS_TO_FIX.map { |f| "#{f} LIKE '%translatedText%'" }
    
    products = Product.where(query_parts.join(" OR "))
    products = products.limit(limit) if limit
    
    total = products.count
    processed = 0
    fixed = 0
    
    Rails.logger.info "Starting ProductTranslationRepairService for #{total} products..."
    
    products.find_each do |product|
      processed += 1
      Rails.logger.info "Repairing translation for product SKU: #{product.sku} (#{processed}/#{total})"
      res = repair_product(product)
      fixed += 1 if res[:fixed]
    end
    
    Rails.logger.info "ProductTranslationRepairService finished. Processed: #{processed}, Fixed: #{fixed}"
    { processed: processed, fixed: fixed }
  end

  def self.repair_product(product)
    updates = {}
    was_fixed = false
    
    FIELDS_TO_FIX.each do |field_ru|
      val = product.read_attribute(field_ru)
      if val.present? && val.include?('translatedText')
        # Находим оригинальное поле
        field_original = field_ru.sub(/_ru$/, '')
        # Специальный случай для name_ru -> name
        field_original = 'name' if field_ru == 'name_ru'
        
        original_text = product.read_attribute(field_original)
        if original_text.present?
          # Переводим заново, принудительно (force: true)
          new_translation = TranslationService.translate(original_text, force: true, context: "Product SKU: #{product.sku}, field: #{field_ru}")
          if new_translation.present? && !TranslationService.invalid_translation?(new_translation, original_text)
            updates[field_ru] = new_translation
            was_fixed = true
          end
        end
      end
    end

    if updates.any?
      product.update_columns(updates)
    end
    
    { fixed: was_fixed, updates: updates }
  end
end
