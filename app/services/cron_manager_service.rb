# Сервис для управления cron задачами через Sidekiq-Cron
class CronManagerService
  class << self
    # Создать или обновить cron задачу
    def setup_cron_schedule(cron_schedule)
      return unless cron_schedule.enabled?

      job_name = "parser_#{cron_schedule.task_type}"

      # Удаляем существующую задачу, если есть
      Sidekiq::Cron::Job.find(job_name)&.destroy

      job_class = job_class_for_task_type(cron_schedule.task_type)

      # Все parser_* джобы — ActiveJob. Без active_job: true sidekiq-cron
      # вызывает perform_async и падает на ActiveJob::ConfiguredJob.
      Sidekiq::Cron::Job.create(
        name: job_name,
        cron: cron_schedule.schedule,
        class: job_class.to_s,
        args: [],
        active_job: true,
        queue: active_job_base_queue_name(job_class)
      )

      Rails.logger.info "Cron schedule created: #{job_name} with schedule #{cron_schedule.schedule}"
    end

    # Удалить cron задачу
    def remove_cron_schedule(cron_schedule)
      job_name = "parser_#{cron_schedule.task_type}"
      job = Sidekiq::Cron::Job.find(job_name)

      if job
        job.destroy
        Rails.logger.info "Cron schedule removed: #{job_name}"
      end
    end

    # Синхронизировать все cron расписания из базы данных
    def sync_all_schedules
      CronSchedule.enabled.find_each do |schedule|
        setup_cron_schedule(schedule)
      end

      # Удаляем задачи, которые отключены или удалены из БД
      active_task_types = CronSchedule.enabled.pluck(:task_type)
      Sidekiq::Cron::Job.all.each do |job|
        if job.name.start_with?('parser_') && !active_task_types.include?(job.name.sub('parser_', ''))
          job.destroy
          Rails.logger.info "Removed inactive cron job: #{job.name}"
        end
      end
    end

    # Проверить и запустить задачи, которые должны выполниться
    def check_and_run_due_tasks
      CronSchedule.enabled.due.find_each do |schedule|
        job_class = job_class_for_task_type(schedule.task_type)
        job_class.perform_later

        schedule.mark_as_run!
        Rails.logger.info "Scheduled task #{schedule.task_type} executed"
      end
    end

    private

    # ActiveJob сам добавит queue_name_prefix; sidekiq-cron ждёт имя без префикса.
    def active_job_base_queue_name(job_class)
      name = job_class.queue_name.to_s
      prefix = ActiveJob::Base.queue_name_prefix.to_s
      delimiter = ActiveJob::Base.queue_name_delimiter.presence || "_"

      if prefix.present? && name.start_with?("#{prefix}#{delimiter}")
        name.delete_prefix("#{prefix}#{delimiter}")
      else
        name
      end
    end

    def job_class_for_task_type(task_type)
      case task_type
      when 'categories'
        ParseCategoriesJob
      when 'products'
        ParseProductsJob
      when 'bestsellers'
        ParseBestsellersJob
      when 'popular_categories'
        ParsePopularCategoriesJob
      when 'category_images'
        DownloadCategoryImagesJob
      when 'product_images'
        DownloadProductImagesJob
      when 'extended_attributes'
        FetchProductExtendedAttributesJob
      when 'currency_rates'
        FetchCurrencyRatesJob
      when 'pl_prices_stock'
        RefreshPlPricesAndStockJob
      when 'seo_catalog_pages'
        RegenerateSeoCatalogPagesJob
      when 'cancel_expired_unpaid_orders'
        CancelExpiredUnpaidOrdersJob
      when 'send_abandoned_cart_emails'
        SendAbandonedCartEmailsJob
      else
        raise ArgumentError, "Unknown task type: #{task_type}"
      end
    end
  end
end
