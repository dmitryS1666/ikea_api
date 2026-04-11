# frozen_string_literal: true

# Полный сброс текущей логической Redis БД (FLUSHDB), куда смотрит REDIS_URL.
#
# У вас в config/initializers/sidekiq.rb и config/application.rb (cache_store) по умолчанию
# один и тот же URL → в одной DB лежат и Sidekiq, и Rails.cache. После flush:
#   - очереди, retry, scheduled, dead, статистика Sidekiq;
#   - записи sidekiq-cron в Redis (расписания подтянутся при следующем старте воркера из CronManagerService);
#   - весь кэш приложения в Redis.
#
# Перед запуском остановите Sidekiq (и всё, что пишет в этот Redis), затем:
#
#   RAILS_ENV=production CONFIRM_FLUSH_REDIS=YES bundle exec rake redis:flushdb
#
# Только показать URL и номер DB без удаления:
#
#   bundle exec rake redis:flushdb_dry_run
#
namespace :redis do
  def redis_url
    ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  end

  def redis_url_for_log(url)
    u = URI.parse(url)
    u.password = "[redacted]" if u.password.present?
    u.to_s
  end

  desc "Показать REDIS_URL (без пароля) и номер DB; данных не удаляет"
  task flushdb_dry_run: :environment do
    url = redis_url
    u = URI.parse(url)
    puts "REDIS_URL: #{redis_url_for_log(url)}"
    puts "DB index: #{u.path.present? && u.path != '/' ? u.path.delete_prefix('/') : '0'}"
    puts "Для FLUSHDB этой базы: CONFIRM_FLUSH_REDIS=YES bundle exec rake redis:flushdb"
  end

  desc "FLUSHDB для REDIS_URL. Требует CONFIRM_FLUSH_REDIS=YES. Остановите Sidekiq заранее."
  task flushdb: :environment do
    unless ENV["CONFIRM_FLUSH_REDIS"] == "YES"
      abort <<~MSG.squish
        Отказ: установите в окружении ровно CONFIRM_FLUSH_REDIS=YES
        (и лучше остановите Sidekiq). Подробности: rake -D redis:flushdb и комментарий в lib/tasks/redis_flushdb.rake
      MSG
    end

    require "redis"

    url = redis_url
    puts "FLUSHDB #{redis_url_for_log(url)}"

    Redis.new(url: url).flushdb
    puts "Готово: текущая Redis DB очищена."
  end
end
