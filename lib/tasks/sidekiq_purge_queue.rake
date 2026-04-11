# frozen_string_literal: true

# Отдельный файл: проще убедиться на сервере, что задача задеплоена (`ls lib/tasks/sidekiq_purge_queue.rake`).
namespace :sidekiq do
  desc "Удалить джобы из очереди Sidekiq (QUEUE=..., опционально CLASS_SUBSTRING=...)"
  task purge_queue: :environment do
    require "sidekiq/api"

    qname = ENV["QUEUE"].to_s.strip
    abort("Задайте QUEUE=ikea_api_production_parser (или ikea_api_production_default и т.д.)") if qname.blank?

    pat = ENV["CLASS_SUBSTRING"].to_s.strip
    queue = Sidekiq::Queue.new(qname)
    jobs = queue.to_a
    removed = 0
    jobs.each do |job|
      next if pat.present? && !job.display_class.to_s.include?(pat)

      job.delete
      removed += 1
    end
    puts "Удалено #{removed} из очереди #{qname}#{pat.present? ? " (фильтр класса: #{pat})" : ""}"
  end
end
