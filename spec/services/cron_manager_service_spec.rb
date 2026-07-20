require 'rails_helper'

RSpec.describe CronManagerService do
  let(:cron_schedule) { create(:cron_schedule, task_type: 'categories', schedule: '0 2 * * *') }

  describe '.setup_cron_schedule' do
    it 'creates Sidekiq cron job' do
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
      allow(Sidekiq::Cron::Job).to receive(:create)
      
      CronManagerService.setup_cron_schedule(cron_schedule)
      
      expect(Sidekiq::Cron::Job).to have_received(:create).with(
        name: 'parser_categories',
        cron: '0 2 * * *',
        class: 'ParseCategoriesJob',
        args: [],
        active_job: true,
        queue: 'parser'
      )
    end

    it 'removes existing job before creating new one' do
      existing_job = double('job')
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(existing_job)
      allow(existing_job).to receive(:destroy)
      allow(Sidekiq::Cron::Job).to receive(:create)
      
      CronManagerService.setup_cron_schedule(cron_schedule)
      
      expect(existing_job).to have_received(:destroy)
    end

    it 'does not create job if schedule is disabled' do
      disabled_schedule = create(:cron_schedule, enabled: false)

      expect(Sidekiq::Cron::Job).not_to receive(:create)
      CronManagerService.setup_cron_schedule(disabled_schedule)
    end

    it 'creates SEO catalog pages regeneration cron job' do
      schedule = create(:cron_schedule, task_type: 'seo_catalog_pages', schedule: '0 8 * * *')
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
      allow(Sidekiq::Cron::Job).to receive(:create)

      CronManagerService.setup_cron_schedule(schedule)

      expect(Sidekiq::Cron::Job).to have_received(:create).with(
        name: 'parser_seo_catalog_pages',
        cron: '0 8 * * *',
        class: 'RegenerateSeoCatalogPagesJob',
        args: [],
        active_job: true,
        queue: 'default'
      )
    end

    it 'creates auto-cancel cron job for expired unpaid orders' do
      schedule = create(:cron_schedule, task_type: 'cancel_expired_unpaid_orders', schedule: '*/5 * * * *')
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
      allow(Sidekiq::Cron::Job).to receive(:create)

      CronManagerService.setup_cron_schedule(schedule)

      expect(Sidekiq::Cron::Job).to have_received(:create).with(
        name: 'parser_cancel_expired_unpaid_orders',
        cron: '*/5 * * * *',
        class: 'CancelExpiredUnpaidOrdersJob',
        args: [],
        active_job: true,
        queue: 'default'
      )
    end

    it 'creates pl_prices_stock cron as ActiveJob on parser queue' do
      schedule = create(:cron_schedule, task_type: 'pl_prices_stock', schedule: '0 5 * * *')
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
      allow(Sidekiq::Cron::Job).to receive(:create)

      CronManagerService.setup_cron_schedule(schedule)

      expect(Sidekiq::Cron::Job).to have_received(:create).with(
        name: 'parser_pl_prices_stock',
        cron: '0 5 * * *',
        class: 'RefreshPlPricesAndStockJob',
        args: [],
        active_job: true,
        queue: 'parser'
      )
    end

    it 'enqueues ActiveJob via perform_later instead of perform_async' do
      schedule = create(:cron_schedule, task_type: 'pl_prices_stock', schedule: '0 5 * * *')

      CronManagerService.setup_cron_schedule(schedule)

      job = Sidekiq::Cron::Job.find('parser_pl_prices_stock')
      expect(job).to be_present

      expect {
        job.enque!
      }.to have_enqueued_job(RefreshPlPricesAndStockJob)
    end
  end

  describe '.remove_cron_schedule' do
    it 'removes Sidekiq cron job' do
      job = double('job')
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(job)
      allow(job).to receive(:destroy)
      
      CronManagerService.remove_cron_schedule(cron_schedule)
      
      expect(job).to have_received(:destroy)
    end

    it 'handles missing job gracefully' do
      allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
      
      expect { CronManagerService.remove_cron_schedule(cron_schedule) }.not_to raise_error
    end
  end

  describe '.sync_all_schedules' do
    it 'syncs all enabled schedules' do
      enabled1 = create(:cron_schedule, enabled: true, task_type: 'categories')
      enabled2 = create(:cron_schedule, enabled: true, task_type: 'products')
      disabled = create(:cron_schedule, enabled: false, task_type: 'bestsellers')
      
      allow(CronManagerService).to receive(:setup_cron_schedule)
      allow(Sidekiq::Cron::Job).to receive(:all).and_return([])
      
      CronManagerService.sync_all_schedules
      
      expect(CronManagerService).to have_received(:setup_cron_schedule).with(enabled1)
      expect(CronManagerService).to have_received(:setup_cron_schedule).with(enabled2)
      expect(CronManagerService).not_to have_received(:setup_cron_schedule).with(disabled)
    end
  end

  describe '.check_and_run_due_tasks' do
    it 'runs due tasks' do
      due_schedule = create(:cron_schedule, enabled: true, task_type: 'categories')
      future_schedule = create(:cron_schedule, enabled: true, task_type: 'products')
      
      # Обновляем next_run_at напрямую, обходя before_save
      due_schedule.update_column(:next_run_at, 1.hour.ago)
      future_schedule.update_column(:next_run_at, 1.hour.from_now)
      
      allow(ParseCategoriesJob).to receive(:perform_later)
      allow(ParseProductsJob).to receive(:perform_later)
      
      CronManagerService.check_and_run_due_tasks
      
      expect(ParseCategoriesJob).to have_received(:perform_later)
      expect(ParseProductsJob).not_to have_received(:perform_later)
      expect(due_schedule.reload.last_run_at).to be_present
    end
  end
end

