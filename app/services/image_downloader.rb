# Сервис для загрузки изображений
# Использует ImageStorage для абстракции над различными хранилищами (локальное, S3, Cloudinary)
require_relative 'image_storage/base'
require_relative 'image_storage/local'
require_relative 'image_storage/s3'
require_relative 'image_storage/cloudinary'

class ImageDownloader
  # Конкурентность загрузки (можно настроить через ENV)
  CONCURRENCY_IMAGES = ENV.fetch('IMG_DL_IMAGES', '6').to_i
  
  # Определяем, какое хранилище использовать (по умолчанию локальное)
  def self.storage
    @storage ||= begin
      storage_type = ENV.fetch('IMAGE_STORAGE_TYPE', 'local').downcase
      case storage_type
      when 's3'
        ImageStorage::S3
      when 'cloudinary'
        ImageStorage::Cloudinary
      else
        ImageStorage::Local
      end
    end
  end

  class << self
    # Загрузить изображение категории
    def download_category_image(category, image_url)
      return nil unless image_url.present?
      
      begin
        stored_path = storage.upload(image_url, category_id: category.ikea_id)
        return nil unless stored_path
        
        # Сохраняем путь или URL в зависимости от типа хранилища
        if storage == ImageStorage::Local
          category.update_column(:local_image_path, stored_path)
        else
          # Для облачных хранилищ сохраняем URL
          category.update_column(:local_image_path, storage.url(stored_path))
        end
        
        stored_path
      rescue => e
        Rails.logger.error "Failed to download category image #{image_url}: #{e.message}"
        nil
      end
    end

    # Загрузить изображения продукта
    def download_product_images(product, image_urls, limit: nil)
      return [] unless image_urls.present?
      
      # Нормализуем image_urls - может быть массив или строка (JSON)
      urls = if image_urls.is_a?(String)
               begin
                 JSON.parse(image_urls)
               rescue JSON::ParserError
                 Rails.logger.warn "ImageDownloader: Failed to parse image_urls JSON: #{image_urls[0..100]}"
                 []
               end
             else
               Array(image_urls)
             end
      
      return [] if urls.empty?
      
      # Убираем дубликаты и пустые значения из исходных URL
      urls = urls.compact.map(&:to_s).map(&:strip).uniq
      
      # 1. Получаем уже загруженные изображения и проверяем их целостность
      existing_local_images = if product.local_images.is_a?(String)
                                begin
                                  JSON.parse(product.local_images) || []
                                rescue JSON::ParserError
                                  []
                                end
                              else
                                Array(product.local_images) || []
                              end
      
      # Очищаем от дублей и пустых значений
      existing_local_images = existing_local_images.compact.uniq
      
      # Проверяем существующие изображения на "здоровье"
      healthy_local_images = []
      existing_local_images.each do |path|
        if storage.respond_to?(:healthy?) ? storage.healthy?(path) : storage.exists?(path)
          healthy_local_images << path
        else
          # Если картинка битая или отсутствует - удаляем
          Rails.logger.warn "ImageDownloader: Image #{path} is broken or missing, deleting from product #{product.sku}"
          storage.delete(path) if storage.exists?(path)
        end
      end
      
      local_paths = Set.new(healthy_local_images)
      downloaded = 0
      failed = 0
      
      # Выбираем только те URL, которые еще не загружены (или были битыми)
      urls_to_process = limit ? urls.first(limit) : urls
      
      Rails.logger.info "ImageDownloader: Starting download/verification of #{urls_to_process.length} images for product #{product.sku} (healthy: #{local_paths.size}, storage: #{storage.name})"
      
      # Параллельная загрузка с ограничением конкурентности
      mutex = Mutex.new
      threads = []
      active_threads = 0
      
      urls_to_process.each do |image_url|
        next unless image_url.present?
        
        # Ждем, пока освободится место для нового потока
        while active_threads >= CONCURRENCY_IMAGES
          sleep(0.1)
        end
        
        threads << Thread.new do
          mutex.synchronize { active_threads += 1 }
          
          begin
            # Используем storage для загрузки
            stored_path = storage.upload(image_url, product_sku: product.sku)
            
            if stored_path
              # Для облачных хранилищ получаем URL, для локального - путь
              path_or_url = if storage == ImageStorage::Local
                            stored_path.start_with?('/') ? stored_path : "/#{stored_path}"
                          else
                            storage.url(stored_path)
                          end
              
              mutex.synchronize do
                local_paths.add(path_or_url)
                downloaded += 1
              end
            else
              mutex.synchronize { failed += 1 }
            end
          rescue => e
            mutex.synchronize { failed += 1 }
            Rails.logger.error "ImageDownloader: Failed to download product image #{image_url} for #{product.sku}: #{e.message}"
          ensure
            mutex.synchronize { active_threads -= 1 }
          end
        end
      end
      
      # Ждем завершения всех потоков
      threads.each(&:join)
      
      # Обновляем данные продукта
      images_total = urls.length
      images_stored = local_paths.size
      images_incomplete = images_stored < images_total
      local_images_array = local_paths.to_a.compact.uniq
      
      # Обновляем только если что-то изменилось
      if downloaded > 0 || images_incomplete != product.images_incomplete || local_images_array != existing_local_images || images_stored != product.images_stored
        product.update_columns(
          local_images: local_images_array.to_json,
          images_stored: images_stored,
          images_total: images_total,
          images_incomplete: images_incomplete
        )
        Rails.logger.info "ImageDownloader: Product #{product.sku} - downloaded: #{downloaded}, failed: #{failed}, total: #{images_total}, stored: #{images_stored}, incomplete: #{images_incomplete}"
      end
      
      local_images_array
    end

  end
end
