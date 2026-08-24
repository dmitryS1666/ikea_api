# Сервис для отправки уведомлений в Telegram
# Используем простой HTTP запрос к Telegram Bot API
require 'net/http'
require 'uri'

class TelegramService
  class << self
    def send_message(text, parse_mode: 'HTML')
      return unless bot_token.present? && chat_id.present?

      begin
        uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
        response = Net::HTTP.post_form(uri, {
          chat_id: chat_id,
          text: text,
          parse_mode: parse_mode
        })
        
        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error "Telegram API error: #{response.body}"
        end
      rescue => e
        Rails.logger.error "Telegram error: #{e.message}"
        # Не падаем, если Telegram недоступен
      end
    end

    def send_parser_started(task_type, limit: nil)
      message = "🚀 <b>Парсинг запущен</b>\n\n"
      message += "Тип: #{task_type_name(task_type)}\n"
      message += "Ограничение: #{limit || 'без ограничений'}\n"
      message += "Время: #{Time.current.strftime('%d.%m.%Y %H:%M:%S')}"
      
      send_message(message)
    end

    def send_parser_completed(task_type, stats)
      message = "✅ <b>Парсинг завершен</b>\n\n"
      message += "Тип: #{task_type_name(task_type)}\n"
      message += "Обработано: #{stats[:processed] || 0}\n"
      message += "Создано: #{stats[:created] || 0}\n"
      message += "Обновлено: #{stats[:updated] || 0}\n"
      message += "Ошибок: #{stats[:errors] || 0}\n"
      message += "Время выполнения: #{format_duration(stats[:duration] || 0)}"
      
      send_message(message)
    end

    def send_product_video_stats(payload)
      data = (payload || {}).to_h
      message = "📊 <b>Видео товаров IKEA — оценка хранения</b>\n\n"
      message += "Товаров проверено: #{data['products_checked'] || 0}\n"
      message += "С видео: #{data['products_with_videos'] || 0}\n"
      message += "С файлами (mp4/pvid): #{data['products_with_downloadable_videos'] || 0}\n"
      message += "Только embed (YouTube/Vimeo): #{data['products_with_embeds'] || 0}\n"
      message += "Уникальных файлов с размером: #{data['unique_sized_videos'] || 0}\n"
      message += "Размер неизвестен: #{data['size_unknown'] || 0}\n"
      message += "Страниц IKEA запрошено: #{data['live_fetched'] || 0}\n\n"
      message += "<b>Уникальные файлы (реальный объём на диск): #{data['unique_total_human'] || '0 B'}</b>\n"
      message += "Если копировать файл на каждый товар: #{data['product_total_human'] || '0 B'}\n"
      message += "Мин / ср / макс: #{human_bytes_line(data)}\n"
      if data["report_path"].present?
        message += "\nОтчёт: #{data['report_path']}"
      end

      send_message(message)
    end

    def send_product_document_stats(payload)
      data = (payload || {}).to_h
      message = "📊 <b>Инструкции товаров IKEA — оценка хранения</b>\n\n"
      message += "Товаров проверено: #{data['products_checked'] || 0}\n"
      message += "С инструкциями: #{data['products_with_documents'] || 0}\n"
      message += "Уникальных файлов с размером: #{data['unique_sized_documents'] || 0}\n"
      message += "Размер неизвестен: #{data['size_unknown'] || 0}\n"
      message += "Страниц IKEA запрошено: #{data['live_fetched'] || 0}\n\n"
      message += "<b>Уникальные файлы (реальный объём на диск): #{data['unique_total_human'] || '0 B'}</b>\n"
      message += "Если копировать файл на каждый товар: #{data['product_total_human'] || '0 B'}\n"
      message += "Мин / ср / макс: #{human_bytes_line(data)}\n"
      if data["report_path"].present?
        message += "\nОтчёт: #{data['report_path']}"
      end

      send_message(message)
    end

    def send_parser_error(task_type, error)
      message = "❌ <b>Ошибка парсинга</b>\n\n"
      message += "Тип: #{task_type_name(task_type)}\n"
      message += "Ошибка: #{error.message}\n"
      message += "Время: #{Time.current.strftime('%d.%m.%Y %H:%M:%S')}"
      
      send_message(message)
    end

    private

    def bot_token
      ENV['TELEGRAM_BOT_TOKEN']
    end

    def chat_id
      ENV['TELEGRAM_CHAT_ID']
    end

    def task_type_name(task_type)
      {
        'categories' => 'Категории',
        'products' => 'Продукты',
        'bestsellers' => 'Хиты продаж',
        'popular_categories' => 'Популярные категории',
        'category_images' => 'Картинки категорий',
        'product_images' => 'Картинки продуктов',
        'extended_attributes' => 'Расширенные атрибуты продуктов',
        'currency_rates' => 'Курсы валют',
        'fix_missing_images' => 'Докачка отсутствующих картинок',
        'extended_attributes_by_skus' => 'Загрузка атрибутов по списку SKU',
        'recover_missing_images' => 'Восполнение ссылок на картинки',
        'recover_missing_weights' => 'Восполнение веса товаров',
        'recover_missing_packaging_dimensions' => 'Восполнение размеров упаковки',
        'recover_broken_product_images' => 'Восстановление битых картинок',
        'refresh_category_lt' => 'Актуализация категории (список SKU с LT)',
        'harvest_category_related_products' => 'Сбор category related_products (1-й/последний SKU)',
        'pl_prices_stock' => 'Цены и остатки (PL, все или один SKU)',
        'count_broken_packaging_dimensions' => 'Подсчёт: битая ВГХ упаковки',
        'count_broken_product_images' => 'Подсчёт: битые картинки товара',
        'count_broken_product_translations' => 'Подсчёт: польский текст в API',
        'recover_broken_product_translations' => 'Восстановление переводов (LT / AI)',
        'collect_product_video_stats' => 'Статистика размера видео товаров',
        'collect_product_document_stats' => 'Статистика размера инструкций товаров'
      }[task_type.to_s] || task_type.to_s
    end

    def human_bytes_line(data)
      min = CollectProductVideoStatsJob::Collector.human_bytes(data["min_bytes"])
      avg = CollectProductVideoStatsJob::Collector.human_bytes(data["avg_bytes"])
      max = CollectProductVideoStatsJob::Collector.human_bytes(data["max_bytes"])
      "#{min} / #{avg} / #{max}"
    end

    def format_duration(seconds)
      return '0 сек' if seconds.nil? || seconds.zero?
      
      hours = (seconds / 3600).to_i
      minutes = ((seconds % 3600) / 60).to_i
      secs = (seconds % 60).to_i
      
      parts = []
      parts << "#{hours} ч" if hours > 0
      parts << "#{minutes} мин" if minutes > 0
      parts << "#{secs} сек" if secs > 0
      
      parts.join(' ') || '0 сек'
    end
  end
end

