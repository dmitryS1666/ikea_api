# frozen_string_literal: true

# Отдельный файл: проще убедиться на сервере, что задача задеплоена (`ls lib/tasks/sidekiq_purge_queue.rake`).
#
# Примеры:
#   QUEUE=ikea_api_production_parser CLASS_SUBSTRING=ReindexProductFiltersJob \\
#     RAILS_ENV=production bundle exec rake sidekiq:purge_queue
#
#   RAILS_ENV=production bundle exec rake 'sidekiq:purge_queue[ikea_api_production_parser,ReindexProductFiltersJob]'
#
#   rails sidekiq:purge_queue — то же самое, но переменные QUEUE / CLASS_SUBSTRING нужно задать в той же строке,
#   иначе rake не увидит окружение (см. первый пример).
namespace :sidekiq do
  desc "Удалить джобы из очереди (QUEUE= или rake sidekiq:purge_queue[qname,ClassSub]; опционально CLASS_SUBSTRING= / второй аргумент)"
  task :purge_queue, [:queue_name, :class_substring] => :environment do |_t, args|
    require "sidekiq/api"

    args ||= {}
    qname = ENV["QUEUE"].to_s.strip.presence || args[:queue_name].to_s.strip
    abort("Задайте QUEUE=... или rake 'sidekiq:purge_queue[ikea_api_production_parser]'") if qname.blank?

    pat = ENV["CLASS_SUBSTRING"].to_s.strip.presence || args[:class_substring].to_s.strip

    job_matches = lambda do |job|
      if pat.blank?
        true
      else
        parts = [job.display_class.to_s, job.item["wrapped"].to_s, job.item["class"].to_s]
        a0 = job.item["args"]&.first
        if a0.is_a?(Hash)
          parts << a0["job_class"].to_s
          parts << a0["wrapped"].to_s
        end
        parts.join(" ").include?(pat)
      end
    end

    queue = Sidekiq::Queue.new(qname)
    jobs = queue.to_a
    puts "В очереди «#{qname}» сейчас джоб: #{jobs.size}"

    removed = 0
    jobs.each do |job|
      next unless job_matches.call(job)

      job.delete
      removed += 1
    end
    puts "Удалено #{removed}#{pat.present? ? " (подстрока в классе/обёртке: #{pat})" : ""}"
  end
end
