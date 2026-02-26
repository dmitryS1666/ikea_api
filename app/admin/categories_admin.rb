Trestle.resource(:categories, model: Category) do
  menu do
    item :categories, icon: "fa fa-folder", priority: 1, label: "Категории", group: "Catalog"
  end

  scopes do
    scope :all, default: true
    scope :top_level, -> { Category.top_level }, label: "Верхнеуровневые"
    scope :top, -> { Category.top }, label: "ТОП-категории"
    scope :custom, -> { Category.custom }, label: "Кастомные (Спецпредложения)"
    scope :popular, -> { Category.popular }, label: "Популярные"
    scope :active, -> { Category.active }, label: "Активные"
  end

  # Используем кастомный index view с древовидной структурой
  controller do
    def index
      # Получаем текущий scope из параметров
      @current_scope = params[:scope] || 'all'
      
      # В development режиме отключаем кэширование для упрощения отладки
      if Rails.env.development?
        # Без кэширования - всегда свежие данные
        # Используем новую связь many-to-many через category_products
        @product_counts = CategoryProduct.select(:category_id).group(:category_id).count
        
        # Предзагружаем счетчики дочерних категорий одним запросом (оптимизация N+1)
        all_categories = Category.select(:ikea_id, :parent_ids).to_a
        @children_counts = Hash.new(0)
        
        all_categories.each do |category|
          parent_ids = Category.normalize_parent_ids(category.parent_ids)
          parent_ids.each do |parent_id|
            @children_counts[parent_id.to_s] += 1
          end
        end
        
        # Сохраняем счетчики в переменные экземпляра для доступа в table блоке
        @_product_counts_cache = @product_counts
        @_children_counts_cache = @children_counts
        
        # Применяем фильтрацию в зависимости от выбранного scope
        base_query = Category.all
        case @current_scope
        when 'top_level'
          base_query = Category.top_level
        when 'top'
          base_query = Category.top
        when 'custom'
          base_query = Category.custom
        when 'popular'
          base_query = Category.popular
        when 'active'
          base_query = Category.active
        end

        # Дерево категорий без кэша
        categories = base_query.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_top, :top_position, :is_custom, :is_deleted, :is_important, :header_menu, :header_menu_position)
                             .order(:name)
                             .to_a
        @categories_tree = Category.build_tree(categories)
        Rails.logger.info "CategoriesAdmin: Built tree with #{@categories_tree.count} top-level categories (DEV: no cache, scope: #{@current_scope})"
      else
        # В production/staging используем кэширование для производительности
        # Кэшируем счетчики продуктов отдельно для быстрого доступа (увеличено до 30 минут)
        @product_counts = Rails.cache.fetch("categories_product_counts", expires_in: 30.minutes) do
          # Используем новую связь many-to-many через category_products
          CategoryProduct.select(:category_id).group(:category_id).count
        end
        
        # Предзагружаем счетчики дочерних категорий одним запросом (оптимизация N+1)
        @children_counts = Rails.cache.fetch("categories_children_counts", expires_in: 30.minutes) do
          # Получаем все категории с их parent_ids
          all_categories = Category.select(:ikea_id, :parent_ids).to_a
          children_counts = Hash.new(0)
          
          all_categories.each do |category|
            parent_ids = Category.normalize_parent_ids(category.parent_ids)
            parent_ids.each do |parent_id|
              children_counts[parent_id.to_s] += 1
            end
          end
          
          children_counts
        end
        
        # Сохраняем счетчики в переменные экземпляра для доступа в table блоке
        @_product_counts_cache = @product_counts
        @_children_counts_cache = @children_counts
        
        # Кэшируем дерево категорий на 30 минут (увеличено с 5 минут)
        # Ключ кэша включает максимальное время обновления категорий и текущий scope
        max_updated_at = Rails.cache.fetch("categories_max_updated_at", expires_in: 30.minutes) do
          Category.maximum(:updated_at)
        end
        cache_key = "categories_tree_#{@current_scope}_#{max_updated_at&.to_i || 0}"
        
        @categories_tree = Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
          # Применяем фильтрацию в зависимости от выбранного scope
          base_query = Category.all
          case @current_scope
          when 'top_level'
            base_query = Category.top_level
          when 'top'
            base_query = Category.top
          when 'custom'
            base_query = Category.custom
          when 'popular'
            base_query = Category.popular
          when 'active'
            base_query = Category.active
          end

          # Оптимизированный запрос - загружаем только нужные поля
          categories = base_query.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_top, :top_position, :is_custom, :is_deleted, :is_important, :header_menu, :header_menu_position)
                               .order(:name)
                               .to_a
          tree = Category.build_tree(categories)
          Rails.logger.info "CategoriesAdmin: Built tree with #{tree.count} top-level categories (scope: #{@current_scope})"
          tree
        end
      end
      
      Rails.logger.info "CategoriesAdmin: Rendering tree with #{@categories_tree.count} top-level categories"
      @filters_reindex_task = ParserTask.by_type('category_filters').recent.first
      @filters_reindex_running = ParserTask.by_type('category_filters')
                                            .where(status: ['running', 'pending'])
                                            .exists?
      render "trestle/categories/index"
    end

    def new
      @category = Category.new(params[:category]&.to_unsafe_h || {})
      @category.ikea_id ||= "custom-#{SecureRandom.hex(4)}" if @category.is_custom?
    end

    def toggle_top
      @category = admin.find_instance(params)
      @category.update(is_top: !@category.is_top)
      clear_categories_cache
      redirect_to '/admin/categories', notice: "Категория #{@category.is_top? ? 'добавлена в ТОП' : 'удалена из ТОП'}"
    end

    def toggle_custom
      @category = admin.find_instance(params)
      @category.update(is_custom: !@category.is_custom)
      clear_categories_cache
      redirect_to '/admin/categories', notice: "Категория #{@category.is_custom? ? 'сделана кастомной' : 'сделана обычной'}"
    end

    def import_products_csv
      @category = admin.find_instance(params)
      file = params[:file]
      
      if file.blank?
        flash[:error] = "Выберите CSV файл."
      else
        begin
          require 'csv'
          skus = []
          CSV.foreach(file.path, headers: false) do |row|
            skus << row[0].to_s.strip if row[0].present?
          end
          
          skus.uniq!
          products = Product.where(sku: skus)
          
          # Очищаем старые связи, если нужно, или просто добавляем новые
          # В данном случае, скорее всего, пользователь хочет ЗАМЕНИТЬ список
          @category.category_products.delete_all
          
          products.each do |product|
            @category.category_products.create(product: product)
          end
          
          flash[:notice] = "Импортировано #{products.count} товаров в категорию."
        rescue => e
          flash[:error] = "Ошибка импорта: #{e.message}"
        end
      end
      
      redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
    end

    def show
      @category = admin.find_instance(params)
      render "trestle/categories/show"
    end

    def toggle_active
      @category = admin.find_instance(params)
      @category.update(is_deleted: !@category.is_deleted)
      clear_categories_cache
      redirect_to '/admin/categories', notice: "Категория #{@category.is_deleted? ? 'отключена' : 'включена'}"
    end

    def toggle_popular
      @category = admin.find_instance(params)
      @category.update(is_popular: !@category.is_popular)
      clear_categories_cache
      redirect_to '/admin/categories', notice: "Категория #{@category.is_popular? ? 'добавлена в популярные' : 'удалена из популярных'}"
    end

    def soft_delete
      @category = admin.find_instance(params)
      @category.update(is_deleted: true)
      clear_categories_cache
      redirect_to '/admin/categories', notice: "Категория отключена (мягкое удаление)"
    end

    def reindex_filters
      @category = admin.find_instance(params)
      ReindexCategoryFiltersJob.perform_later(@category.ikea_id)
      redirect_back fallback_location: admin.path(:index),
                    notice: "Запущена переиндексация фильтров для категории #{@category.ikea_id}."
    end

    def reindex_all_filters
      if ParserTask.by_type('category_filters').where(status: ['running', 'pending']).exists?
        redirect_to admin.path(:index), alert: "Переиндексация фильтров уже запущена."
        return
      end

      task = ParserTask.create!(task_type: 'category_filters', status: 'pending')
      job = ReindexAllCategoryFiltersJob.perform_later(task_id: task.id)
      task.update!(job_id: job.job_id) if job.respond_to?(:job_id)

      redirect_to admin.path(:index), notice: "Запущена переиндексация фильтров для всех категорий."
    end

    def import_available_filters
      file = params[:file]
      unless file.respond_to?(:read)
        flash[:error] = "Не выбран файл."
        return redirect_to admin.path(:index)
      end

      result = Categories::AvailableFiltersImportService.new(file).call
      clear_categories_cache

      flash[:notice] = "Импорт завершен: обновлено #{result.updated}, пропущено #{result.skipped}, ошибок #{result.errors}."
      redirect_to admin.path(:index)
    end

    private

    def clear_categories_cache
      # Очищаем кэш дерева категорий и счетчиков продуктов
      Rails.cache.delete_matched("categories_tree_*")
      Rails.cache.delete("categories_product_counts")
      Rails.cache.delete("categories_children_counts")
      Rails.cache.delete("categories_max_updated_at")
      # Очищаем кэш счетчиков дочерних категорий (старый формат для совместимости)
      Rails.cache.delete_matched("category_*_children_count")
    end

    def categories_admin_params
      params.require(:category).permit(
        :ikea_id, :name, :translated_name, :is_popular, :is_top, :top_position, :is_custom, :default_sort, 
        :header_menu, :is_deleted, :header_menu_position, :delivery_days,
        :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
        :icon, :background_image,
        seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
      )
    end
  end

  routes do
    post :toggle_active, on: :member
    post :toggle_popular, on: :member
    post :toggle_top, on: :member
    post :toggle_custom, on: :member
    post :soft_delete, on: :member
    post :reindex_filters, on: :member
    post :import_available_filters, on: :collection
    post :reindex_all_filters, on: :collection
    post :import_products_csv, on: :member
  end

  table do
    column :ikea_id
    column :translated_name 
    column :name, link: true
    column :is_popular do |category|
      status_tag(category.is_popular? ? 'Да' : 'Нет', 
                 category.is_popular? ? :success : :secondary)
    end
    column :is_deleted do |category|
      status_tag(category.is_deleted? ? 'Удалена' : 'Активна', 
                 category.is_deleted? ? :danger : :success)
    end
    column :products_count, label: "Продуктов" do |category|
      # Используем предзагруженные счетчики (избегаем N+1)
      # В development режиме кэш отключен, данные всегда свежие
      product_counts = instance_variable_get(:@_product_counts_cache)
      
      unless product_counts
        # Fallback: если кэш не загружен, получаем напрямую (для совместимости)
        # Используем новую связь many-to-many через category_products
        if Rails.env.development?
          product_counts = CategoryProduct.select(:category_id).group(:category_id).count
        else
          product_counts = Rails.cache.fetch("categories_product_counts", expires_in: 30.minutes) do
            CategoryProduct.select(:category_id).group(:category_id).count
          end
        end
      end
      
      product_counts[category.ikea_id] || 0
    end
    column :children_count, label: "Дочерних категорий" do |category|
      # Используем предзагруженные счетчики (избегаем N+1)
      # В development режиме кэш отключен, данные всегда свежие
      children_counts = instance_variable_get(:@_children_counts_cache)
      
      unless children_counts
        # Fallback: если кэш не загружен, получаем напрямую (для совместимости)
        if Rails.env.development?
          all_categories = Category.select(:ikea_id, :parent_ids).to_a
          children_counts = Hash.new(0)
          all_categories.each do |cat|
            parent_ids = Category.normalize_parent_ids(cat.parent_ids)
            parent_ids.each { |pid| children_counts[pid.to_s] += 1 }
          end
        else
          children_counts = Rails.cache.fetch("categories_children_counts", expires_in: 30.minutes) do
            all_categories = Category.select(:ikea_id, :parent_ids).to_a
            counts = Hash.new(0)
            all_categories.each do |cat|
              parent_ids = Category.normalize_parent_ids(cat.parent_ids)
              parent_ids.each { |pid| counts[pid.to_s] += 1 }
            end
            counts
          end
        end
      end
      
      children_counts[category.ikea_id.to_s] || 0
    end
    column :created_at, align: :center
    actions
  end

  form do |category|
    tab :basic, label: "Основная информация" do
      if category.persisted?
        text_field :ikea_id, readonly: true
      else
        text_field :ikea_id
      end
    
      text_field :name
      text_field :translated_name
      
      divider
      row do
        col(sm: 4) { check_box :is_popular, label: "Популярная категория" }
        col(sm: 4) { check_box :is_deleted, label: "Удалена" }
      end
      row do
        col(sm: 4) { check_box :is_top, label: "ТОП-категория" }
      end
      row do
        col(sm: 2) { number_field :top_position, label: "Позиция в ТОП" }
      end
      divider
      
      # check_box :is_custom, label: "Кастомная категория (Спецпредложение)"
      
      # select :default_sort, Category.default_sorts.keys.map { |s| [s.humanize, s] }
      # check_box :header_menu
      # number_field :header_menu_position
      row do
        col(sm: 2) { number_field :delivery_days, help: "Срок доставки в днях (если не задано, используется значение по умолчанию)" }
      end

      divider
      h3 "Изображения категории"
      divider

      row do
        col(sm: 4) do
          h4 "Иконка"
          concat(content_tag(:div, id: "category-icon-preview-container", style: "margin-bottom: 15px;") do
            content = +""
            if category.persisted? && category.icon.attached?
              icon_path = main_app.rails_storage_proxy_path(category.icon, only_path: true)
              content << content_tag(:div, class: "current-icon-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px; display: inline-block;") do
                image_tag(icon_path,
                        style: "max-width: 100px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;",
                        id: "current-icon-preview")
              end
            end
            content << content_tag(:div, id: "new-icon-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "icon-preview", style: "max-width: 100px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;")
            end
            content.html_safe
          end)

          file_field :icon, label: "Иконка (SVG, PNG, WebP)"
        end

        col(sm: 6) do
          h4 "Фоновое изображение"
          concat(content_tag(:div, id: "category-bg-preview-container", style: "margin-bottom: 15px;") do
            content = +""
            if category.persisted? && category.background_image.attached?
              bg_path = main_app.rails_storage_proxy_path(category.background_image, only_path: true)
              content << content_tag(:div, class: "current-bg-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px; display: inline-block;") do
                image_tag(bg_path,
                        style: "max-width: 200px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;",
                        id: "current-bg-preview")
              end
            end
            content << content_tag(:div, id: "new-bg-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "bg-preview", style: "max-width: 200px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;")
            end
            content.html_safe
          end)

          file_field :background_image, label: "Фон (для превью спецпредложения)"
        end
      end
      
      if category.persisted?
        divider
        h4 "Импорт товаров (CSV)"
        row do
          col(sm: 12) do
            render inline: <<-ERB, locals: { category: category, admin: admin }
              <%= form_tag admin.path(:import_products_csv, id: category.ikea_id), method: :post, multipart: true do %>
                <div class="input-group">
                  <%= file_field_tag :file, accept: ".csv", class: "form-control" %>
                  <%= submit_tag "Загрузить CSV", class: "btn btn-primary" %>
                </div>
                <p class="help-block">Выберите CSV файл со списком SKU товаров (один SKU на строку).</p>
              <% end %>
            ERB
          end
        end
      end

      # JavaScript для предпросмотра иконок и фона
      concat(content_tag(:script, type: "text/javascript") do
        raw <<-JS.strip_heredoc
          (function() {
            function initPreviews() {
              function setupPreview(inputName, previewId, containerId, currentClass) {
                var fileInput = document.querySelector('input[type="file"][name*="[' + inputName + ']"]');
                if (!fileInput) return;

                var preview = document.getElementById(previewId);
                var container = document.getElementById(containerId);
                var currentPreview = document.querySelector('.' + currentClass);

                fileInput.addEventListener('change', function(e) {
                  if (e.target.files && e.target.files[0]) {
                    var reader = new FileReader();
                    reader.onload = function(event) {
                      if (preview) preview.src = event.target.result;
                      if (container) container.style.display = 'inline-block';
                      if (currentPreview) currentPreview.style.display = 'none';
                    };
                    reader.readAsDataURL(e.target.files[0]);
                  } else {
                    if (container) container.style.display = 'none';
                    if (currentPreview) currentPreview.style.display = 'inline-block';
                  }
                });
              }

              setupPreview('icon', 'icon-preview', 'new-icon-preview', 'current-icon-preview');
              setupPreview('background_image', 'bg-preview', 'new-bg-preview', 'current-bg-preview');
            }

            document.addEventListener('turbo:load', initPreviews);
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', initPreviews);
            } else {
              initPreviews();
            }
          })();
        JS
      end)

      divider 
      h3 "Отображение блоков в карточке товара"
      divider 
      
      row do
        col(sm: 6) { check_box :is_bulky, label: "Крупногабаритный товар (Блок услуг)" }
        col(sm: 6) { check_box :show_delivery_block, label: "Показывать доставку" }
      end
      row do
        col(sm: 6) { check_box :show_reviews_block, label: "Показывать отзывы" }
        col(sm: 6) { check_box :show_tips_block, label: "Показывать советы" }
      end
    end

    tab :seo, label: "SEO" do
      seo_obj = category.seo_meta || category.build_seo_meta
      fields_for :seo_meta, seo_obj do |seo|
        row do
          col(sm: 12) { seo.text_field :title, label: "SEO Title", help: "Если пусто, будет сгенерировано автоматически" }
        end
        row do
          col(sm: 12) { seo.text_area :description, label: "SEO Description", help: "Если пусто, будет сгенерировано автоматически" }
        end
        row do
          col(sm: 6) { seo.text_field :keywords, label: "SEO Keywords" }
          col(sm: 6) { seo.text_field :robots, label: "SEO Robots", placeholder: "index, follow" }
        end
        row do
          col(sm: 12) { seo.tinymce :seo_text, label: "SEO Текст" }
        end
      end
    end
  end

  params do |params|
    params.require(:category).permit(
      :ikea_id, :name, :translated_name, :is_popular, :is_top, :top_position, :is_custom, :default_sort,
      :header_menu, :is_deleted, :header_menu_position, :delivery_days,
      :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
      :icon, :background_image,
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end
