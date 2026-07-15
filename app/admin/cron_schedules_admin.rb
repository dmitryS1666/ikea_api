# Админ-панель для управления cron расписаниями
Trestle.resource :cron_schedules, model: CronSchedule do
  menu do
    item :cron_schedules, icon: "fa fa-clock", priority: 2, label: "Cron расписания", group: "Парсер",
                          if: -> { current_user&.allowed_for_admin_resource?(:cron_schedules, :index) }
  end

  # Таблица
  table do
    column :task_type, label: "Тип задачи" do |schedule|
      case schedule.task_type
      when 'categories' then 'Категории'
      when 'products' then 'Продукты'
      when 'bestsellers' then 'Хиты продаж'
      when 'popular_categories' then 'Популярные категории'
      when 'category_images' then 'Картинки категорий'
      when 'product_images' then 'Картинки продуктов'
      when 'extended_attributes' then 'Расширенные атрибуты продуктов'
      when 'currency_rates' then 'Курсы валют'
      when 'pl_prices_stock' then 'Цены и остатки PL'
      when 'seo_catalog_pages' then 'SEO-страницы каталога'
      when 'cancel_expired_unpaid_orders' then 'Автоотмена неоплаченных заказов'
      when 'send_abandoned_cart_emails' then 'Напоминание о брошенной корзине'
      else schedule.task_type
      end
    end
    column :schedule, label: "Расписание"
    column :enabled, label: "Включено" do |schedule|
      enabled = schedule.enabled?
      color = enabled ? 'success' : 'secondary'
      text = enabled ? 'Да' : 'Нет'
      content_tag(:span, text, class: "badge badge-#{color}")
    end
    column :last_run_at, label: "Последний запуск"
    column :next_run_at, label: "Следующий запуск"
    column :created_at, label: "Создано", align: :center
    actions
  end

  form do |schedule|
    tab :basic, label: "Основное" do
      row do
        col(sm: 12) do
          task_types_options = CronSchedule::TASK_TYPES.map do |t|
            label = case t
                    when 'categories' then 'Категории'
                    when 'products' then 'Продукты'
                    when 'bestsellers' then 'Хиты продаж'
                    when 'popular_categories' then 'Популярные категории'
                    when 'category_images' then 'Картинки категорий'
                    when 'product_images' then 'Картинки продуктов'
                    when 'extended_attributes' then 'Расширенные атрибуты продуктов'
                    when 'currency_rates' then 'Курсы валют'
                    when 'pl_prices_stock' then 'Цены и остатки PL'
                    when 'seo_catalog_pages' then 'SEO-страницы каталога'
                    when 'cancel_expired_unpaid_orders' then 'Автоотмена неоплаченных заказов'
      when 'send_abandoned_cart_emails' then 'Напоминание о брошенной корзине'
                    else t
                    end
            [label, t]
          end
          select :task_type, task_types_options, label: "Тип задачи"
        end
      end
      
      text_field :schedule, label: "Расписание (Cron)", placeholder: "0 2 * * * (каждый день в 2:00)", 
                 help: "Cron выражение. Примеры: '0 2 * * *' (каждый день в 2:00), '0 */6 * * *' (каждые 6 часов)"
    end

    sidebar do
      form_group :status, label: "Статус" do
        check_box :enabled, label: "Включено"
      end

      form_group :runs, label: "Запуски" do
        static_field :last_run_at, label: "Последний запуск"
        static_field :next_run_at, label: "Следующий запуск"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end

  # Действия
  controller do
    def create
      schedule = CronSchedule.new(cron_schedule_params)
      
      if schedule.save
        CronManagerService.setup_cron_schedule(schedule) if schedule.enabled?
        flash[:message] = "Cron расписание создано"
        redirect_to admin.instance_path(schedule)
      else
        flash[:error] = "Ошибка: #{schedule.errors.full_messages.join(', ')}"
        render :new
      end
    end

    def update
      schedule = admin.find_instance(params)
      
      if schedule.update(cron_schedule_params)
        if schedule.enabled?
          CronManagerService.setup_cron_schedule(schedule)
        else
          CronManagerService.remove_cron_schedule(schedule)
        end
        flash[:message] = "Cron расписание обновлено"
        redirect_to admin.instance_path(schedule)
      else
        flash[:error] = "Ошибка: #{schedule.errors.full_messages.join(', ')}"
        render :edit
      end
    end

    def sync
      begin
        CronManagerService.sync_all_schedules
        flash[:message] = "Все cron расписания синхронизированы"
      rescue => e
        flash[:error] = "Ошибка синхронизации: #{e.message}"
      end
      redirect_to admin.collection_path
    end

    private

    def cron_schedule_params
      params.require(:cron_schedule).permit(:task_type, :schedule, :enabled)
    end
  end

  routes do
    post :sync, on: :collection
  end
end
