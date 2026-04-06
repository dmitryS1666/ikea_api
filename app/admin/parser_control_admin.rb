# Админ-панель для быстрого управления парсером
Trestle.resource :parser_control, model: ParserControl do
  menu do
    item :parser_control, icon: "fa fa-play-circle", group: :content, label: "Управление парсером"
  end

  # Показываем только форму управления
  controller do
    def index
      redirect_to admin.instance_path(ParserControl.new(id: 'show'))
    end

    def show
      # Показываем задачи со статусом running и pending как активные
      @running_tasks = ParserTask.where(status: ['running', 'pending']).recent.limit(10)
      @recent_tasks = ParserTask.recent.limit(20)
      render "trestle/parser_control/show"
    end

    def active_tasks
      # Кешируем результат на 1 секунду, чтобы уменьшить нагрузку на БД
      cache_key = 'parser_control_active_tasks'
      result = Rails.cache.fetch(cache_key, expires_in: 1.second) do
        # Показываем задачи со статусом running и pending как активные
        running_tasks = ParserTask.where(status: ['running', 'pending']).recent.limit(10)
        
        {
          tasks: running_tasks.map do |task|
            {
              id: task.id,
              task_type: task.task_type,
              processed: task.processed,
              limit: task.limit,
              status: task.status,
              started_at: task.started_at&.iso8601
            }
          end
        }
      end
      
      render json: result
    end

    def start_task
      task_type = params[:task_type]
      limit = params[:limit].present? && params[:limit].to_i > 0 ? params[:limit].to_i : nil
      reset = params[:reset] == '1'
      threads = params[:threads].present? ? params[:threads].to_i : 2
      extra_data = params[:extra_data]
      extra_file = params[:extra_file]
      sku_file_path = params[:sku_file_path]
      
      Rails.logger.info "ParserControlAdmin#start_task called with task_type=#{task_type}, limit=#{limit}, reset=#{reset}, threads=#{threads}"
      
      if task_type.blank?
        flash[:error] = "Необходимо выбрать тип задачи"
        redirect_to admin.instance_path(ParserControl.new(id: 'show'))
        return
      end
      
      begin
        job_class = job_class_for_task_type(task_type)
        
        if job_class.nil?
          flash[:error] = "Неизвестный тип задачи: #{task_type}"
        else
          payload = {}
          
      # Обработка дополнительных данных (SKUs и т.д.)
      if task_type == "extended_attributes_by_skus" || task_type == "recover_broken_product_images" || task_type == "update_all_product_images"
        payload[:skus] = extra_data
        payload[:sku_file_path] = sku_file_path if sku_file_path.present?
      end
      
      # Обработка файла для импорта
      if task_type == 'extended_attrs_import' && extra_file.present?
            import_path = prepare_import_file(extra_file)
            if import_path
              payload[:file_path] = import_path
              payload[:original_name] = extra_file.original_filename
              payload[:cursor] = 0
            else
              flash[:error] = "Не удалось подготовить файл."
              redirect_to admin.instance_path(ParserControl.new(id: 'show'))
              return
            end
          end

          # Создаем ParserTask сразу, чтобы отобразить в админке
          task = ParserTask.create!(
            task_type: task_type,
            status: 'pending',
            limit: limit,
            payload: payload
          )
          
          # Передаем task_id в job и сохраняем job_id
          job = if %w[extended_attrs_import extended_attributes_by_skus fix_translations fix_missing_images translate_all_products update_all_product_images].include?(task_type)
                  # Для полного обновления картинок передаем cleanup: true по умолчанию
                  cleanup = params[:cleanup] == '1' || params[:cleanup].nil?
                  job_class.perform_later(task_id: task.id, reset: reset, cleanup: cleanup, threads: threads)
                else
                  job_class.perform_later(limit: limit, task_id: task.id)
                end
                
          task.update!(job_id: job.job_id) if job.respond_to?(:job_id)
          flash[:message] = "Задача '#{task_type_label(task_type)}' запущена"
        end
      rescue => e
        Rails.logger.error "Error starting task: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        flash[:error] = "Ошибка запуска задачи: #{e.message}"
      end
      
      redirect_to admin.instance_path(ParserControl.new(id: 'show'))
    end

    def stop_task
      task_id = params[:task_id]
      
      Rails.logger.info "ParserControlAdmin#stop_task called with task_id=#{task_id}"
      
      if task_id.blank?
        flash[:error] = "Не указан ID задачи"
        redirect_to admin.instance_path(ParserControl.new(id: 'show'))
        return
      end
      
      begin
        task = ParserTask.find(task_id)
        
        if task.status == 'running' || task.status == 'pending'
          # Останавливаем все связанные Sidekiq jobs
          stopped_jobs = stop_related_jobs(task)
          
          task.update(status: 'failed', error_message: 'Остановлено вручную')
          Rails.logger.info "Task #{task_id} stopped manually. Stopped #{stopped_jobs} jobs"
          flash[:message] = "Задача остановлена#{stopped_jobs > 0 ? " (остановлено #{stopped_jobs} #{stopped_jobs == 1 ? 'job' : 'jobs'})" : ''}"
        else
          flash[:error] = "Задача не запущена (текущий статус: #{task.status})"
        end
      rescue ActiveRecord::RecordNotFound
        flash[:error] = "Задача не найдена"
      rescue => e
        Rails.logger.error "Error stopping task: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        flash[:error] = "Ошибка остановки задачи: #{e.message}"
      end
      
      redirect_to admin.instance_path(ParserControl.new(id: 'show'))
    end

    def resume_task
      task_id = params[:task_id]
      if task_id.blank?
        flash[:error] = "Не указан ID задачи"
        return redirect_to admin.instance_path(ParserControl.new(id: 'show'))
      end

      task = ParserTask.find_by(id: task_id)
      unless task
        flash[:error] = "Задача не найдена"
        return redirect_to admin.instance_path(ParserControl.new(id: 'show'))
      end

      unless %w[extended_attrs_import fix_translations update_all_product_images].include?(task.task_type)
        flash[:error] = "Эта задача не поддерживает продолжение"
        return redirect_to admin.instance_path(ParserControl.new(id: 'show'))
      end

      if %w[running pending].include?(task.status)
        flash[:error] = "Задача уже выполняется"
        return redirect_to admin.instance_path(ParserControl.new(id: 'show'))
      end

      task.update!(status: 'pending', error_message: nil, completed_at: nil)
      
      job_class = job_class_for_task_type(task.task_type)
      job = job_class.perform_later(task_id: task.id)
      
      task.update!(job_id: job.job_id) if job.respond_to?(:job_id)

      flash[:message] = "Продолжение задачи '#{task_type_label(task.task_type)}' запущено"
      redirect_to admin.instance_path(ParserControl.new(id: 'show'))
    rescue => e
      Rails.logger.error "Error resuming task: #{e.class} - #{e.message}"
      flash[:error] = "Ошибка запуска: #{e.message}"
      redirect_to admin.instance_path(ParserControl.new(id: 'show'))
    end

    private

    def prepare_import_file(file)
      FileUtils.mkdir_p(Rails.root.join("tmp", "imports"))
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      import_path = Rails.root.join("tmp", "imports", "extended_attrs_#{timestamp}_#{SecureRandom.hex(4)}.jsonl")

      size = file.size.to_i
      sample = file.read(2048).to_s
      file.rewind
      first_char = sample.lstrip[0]

      if first_char == '['
        return nil if size > 50.megabytes
        parsed = JSON.parse(file.read)
        write_jsonl(import_path, parsed)
      elsif first_char == '{' && !sample.include?("\n")
        begin
          parsed = JSON.parse(file.read)
          write_jsonl(import_path, parsed)
        rescue JSON::ParserError
          file.rewind
          File.open(import_path, "wb") { |f| IO.copy_stream(file, f) }
        end
      else
        File.open(import_path, "wb") { |f| IO.copy_stream(file, f) }
      end

      import_path.to_s
    rescue => e
      Rails.logger.error "Error preparing import file: #{e.message}"
      nil
    ensure
      file.rewind if file.respond_to?(:rewind)
    end

    def write_jsonl(path, parsed)
      items = if parsed.is_a?(Array)
                parsed
              elsif parsed.is_a?(Hash) && parsed["products"].is_a?(Array)
                parsed["products"]
              elsif parsed.is_a?(Hash)
                [parsed]
              else
                []
              end

      File.open(path, "wb") do |f|
        items.each { |item| f.puts(item.to_json) }
      end
    end

    # Остановить все связанные Sidekiq jobs для задачи
    def stop_related_jobs(task)
      require 'sidekiq/api'
      stopped_count = 0
      stopped_jids = []
      
      # Функция для проверки, связан ли job с задачей
      job_matches_task = lambda do |job_item, job_jid|
        # Проверяем по сохраненному job_id (provider_job_id из ActiveJob)
        if task.job_id
          # ActiveJob использует provider_job_id для связи с Sidekiq JID
          # Проверяем напрямую по JID
          if job_jid == task.job_id
            return true
          end
          
          # Также проверяем в job_item
          if job_item['jid'] == task.job_id || job_item['provider_job_id'] == task.job_id
            return true
          end
        end
        
        # Проверяем аргументы job (ActiveJob оборачивает в JobWrapper)
        job_args = job_item['args']&.first || {}
        job_data = job_args.is_a?(Hash) ? job_args : (JSON.parse(job_args.to_s) rescue {})
        
        # Ищем по task_id в аргументах ActiveJob
        # ActiveJob передает аргументы в job_data['arguments'] как массив
        if job_data['arguments'] && job_data['arguments'].is_a?(Array)
          # Аргументы могут быть как хеши, так и простые значения
          task_id_arg = job_data['arguments'].find do |arg|
            if arg.is_a?(Hash)
              arg['task_id'].to_i == task.id
            else
              false
            end
          end
          return true if task_id_arg
        end
        
        # Также проверяем напрямую в args (на случай другого формата)
        if job_data.is_a?(Hash) && job_data['task_id'] && job_data['task_id'].to_i == task.id
          return true
        end
        
        false
      end
      
      # Ищем jobs в очередях
      queues = [Sidekiq::Queue.new('parser'), Sidekiq::Queue.new('default')]
      
      queues.each do |queue|
        queue.each do |job|
          if job_matches_task.call(job.item, job.jid)
            Rails.logger.info "Stopping job #{job.jid} from queue #{queue.name} for task #{task.id}"
            job.delete
            stopped_jids << job.jid
            stopped_count += 1
          end
        end
      end
      
      # Также проверяем в RetrySet и ScheduledSet
      [Sidekiq::RetrySet.new, Sidekiq::ScheduledSet.new].each do |set|
        set.each do |job|
          if job_matches_task.call(job.item, job.jid)
            Rails.logger.info "Stopping job #{job.jid} from #{set.class.name} for task #{task.id}"
            set.delete(job.jid)
            stopped_jids << job.jid
            stopped_count += 1
          end
        end
      end
      
      Rails.logger.info "Stopped #{stopped_count} jobs for task #{task.id}: #{stopped_jids.join(', ')}" if stopped_count > 0
      stopped_count
    rescue => e
      Rails.logger.error "Error stopping related jobs: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      0
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
      when 'fix_missing_images'
        FixMissingImagesJob
      when 'fix_translations'
        RepairProductTranslationsJob
      when 'extended_attrs_import'
        ImportExtendedAttributesFromFileJob
      when 'extended_attributes_by_skus'
        FetchExtendedAttributesBySkusJob
      when 'recover_missing_images'
        RecoverMissingImagesJob
      when 'recover_broken_product_images'
        RecoverBrokenProductImagesJob
      when 'update_all_product_images'
        UpdateAllProductImagesJob
      when 'recover_missing_weights'
        RecoverMissingWeightsJob
      end
    end

    def task_type_label(type)
      {
        'categories' => 'Категории',
        'products' => 'Продукты',
        'bestsellers' => 'Хиты продаж',
        'popular_categories' => 'Популярные категории',
        'category_images' => 'Картинки категорий',
        'product_images' => 'Картинки продуктов',
        'extended_attributes' => 'Расширенные атрибуты продуктов',
        'currency_rates' => 'Курсы валют',
        'category_filters' => 'Переиндексация фильтров категорий',
        'extended_attrs_import' => 'Импорт расширенных атрибутов (JSON)',
        'fix_missing_images' => 'Проверка и докачка отсутствующих картинок',
        'fix_translations' => 'Исправление битых переводов',
        'extended_attributes_by_skus' => 'Загрузка атрибутов по списку SKU',
        'recover_missing_images' => 'Поиск и восполнение ссылок на картинки',
        'recover_broken_product_images' => 'Восстановление битых картинок из лога или по списку SKU',
        'update_all_product_images' => 'Полное обновление всех картинок (WebP + Resumable)',
        'recover_missing_weights' => 'Восполнение недостающего веса (2 потока + прокси)'
      }[type] || type
    end
  end

  routes do
    post :start_task, on: :collection
    post :stop_task, on: :collection
    post :resume_task, on: :collection
    get :active_tasks, on: :collection
  end
end
