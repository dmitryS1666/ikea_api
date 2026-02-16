class FixMissingImagesService
  def self.run(limit: nil)
    products = Product.where.not(images: [nil, "", "[]"])
    products = products.limit(limit) if limit
    
    total = products.count
    processed = 0
    fixed = 0
    
    Rails.logger.info "Starting FixMissingImagesService for #{total} products..."
    
    products.find_each do |product|
      processed += 1
      puts "Processing #{processed}/#{total}: #{product.sku}" if processed % 10 == 0
      
      # Получаем список локальных путей
      local_images = begin
        JSON.parse(product.local_images || "[]")
      rescue
        []
      end
      
      # Проверяем наличие файлов на диске
      missing_any = local_images.any? do |path|
        !File.exist?(Rails.root.join('public', path.sub(/^\//, '')))
      end
      
      # Если хотя бы одной картинки нет на диске или список пуст при наличии оригинальных URL
      if missing_any || (local_images.empty? && product.images.present?)
        Rails.logger.info "Product #{product.sku} has missing images. Redownloading..."
        
        # Получаем оригинальные URL
        original_urls = begin
          JSON.parse(product.images || "[]")
        rescue
          []
        end
        
        if original_urls.any?
          # Очищаем битые пути перед перекачкой, чтобы ImageDownloader не думал, что они есть
          # Но только те, которых реально нет
          valid_local = local_images.select do |path|
            File.exist?(Rails.root.join('public', path.sub(/^\//, '')))
          end
          
          product.update_column(:local_images, valid_local.to_json)
          
          # Запускаем штатный загрузчик
          ImageDownloader.download_product_images(product, original_urls)
          fixed += 1
        end
      end
    end
    
    Rails.logger.info "FixMissingImagesService finished. Processed: #{processed}, Fixed: #{fixed}"
    { processed: processed, fixed: fixed }
  end
end
