# Rake задачи для деплоя и обслуживания
namespace :deploy do
  desc "Очистить кэш Rails"
  task clear_cache: :environment do
    puts "Очистка кэша Rails..."
    Rails.cache.clear
    puts "✓ Кэш очищен"
  end

  desc "Перезагрузить приложение (touch tmp/restart.txt)"
  task restart: :environment do
    puts "Перезагрузка приложения..."
    FileUtils.touch(Rails.root.join('tmp', 'restart.txt'))
    puts "✓ Файл tmp/restart.txt создан"
  end

  desc "Проверить наличие файлов админки парсера"
  task check_parser_admin: :environment do
    puts "Проверка файлов админки парсера..."
    
    files_to_check = [
      'app/admin/parser_control_admin.rb',
      'app/admin/parser_tasks_admin.rb',
      'app/admin/cron_schedules_admin.rb',
      'app/views/trestle/parser_control/show.html.erb'
    ]
    
    all_exist = true
    files_to_check.each do |file|
      path = Rails.root.join(file)
      if path.exist?
        puts "  ✓ #{file}"
      else
        puts "  ✗ #{file} - НЕ НАЙДЕН"
        all_exist = false
      end
    end
    
    if all_exist
      puts "\n✓ Все файлы админки парсера на месте"
    else
      puts "\n✗ Некоторые файлы отсутствуют!"
    end
    
    # Проверяем, что классы загружаются
    puts "\nПроверка загрузки классов..."
    begin
      ParserControlAdmin
      puts "  ✓ ParserControlAdmin загружен"
    rescue => e
      puts "  ✗ ParserControlAdmin не загружен: #{e.message}"
    end
    
    begin
      ParserTasksAdmin
      puts "  ✓ ParserTasksAdmin загружен"
    rescue => e
      puts "  ✗ ParserTasksAdmin не загружен: #{e.message}"
    end
    
    begin
      CronSchedulesAdmin
      puts "  ✓ CronSchedulesAdmin загружен"
    rescue => e
      puts "  ✗ CronSchedulesAdmin не загружен: #{e.message}"
    end
  end
end

