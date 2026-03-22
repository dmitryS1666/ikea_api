Trestle.resource(:categories, model: Category) do
  menu do
    item :categories, icon: "fa fa-folder", group: :catalog, priority: 2, label: "Категории"
  end

  scopes do
    scope :all, default: true
    scope :top_level, -> { Category.top_level }, label: "Верхнеуровневые"
    scope :top, -> { Category.top }, label: "ТОП-категории"
    scope :custom, -> { Category.custom }, label: "Кастомные (Спецпредложения)"
    scope :popular, -> { Category.popular }, label: "Популярные"
    scope :active, -> { Category.active }, label: "Активные"
  end

  controller do
    def index
      # Получаем текущий scope из параметров
      @current_scope = params[:scope] || 'all'
      
      cache_ttl = Rails.env.development? ? 1.minute : 30.minutes
      
      @product_counts = Rails.cache.fetch("categories_product_counts", expires_in: cache_ttl) do
        CategoryProduct.group(:category_id).count
      end
      
      @children_counts = Rails.cache.fetch("categories_children_counts", expires_in: cache_ttl) do
        counts = Hash.new(0)
        Category.pluck(:parent_ids).each do |parent_ids_raw|
          parent_ids = Category.normalize_parent_ids(parent_ids_raw)
          parent_ids.each { |pid| counts[pid.to_s] += 1 }
        end
        counts
      end
      
      @_product_counts_cache = @product_counts
      @_children_counts_cache = @children_counts
      
      max_updated_at = Rails.cache.fetch("categories_max_updated_at", expires_in: cache_ttl) do
        Category.maximum(:updated_at)
      end
      @categories_tree_cache_key = "categories_tree_#{@current_scope}_#{max_updated_at&.to_i || 0}"
      
      @categories_tree = Rails.cache.fetch(@categories_tree_cache_key, expires_in: cache_ttl) do
        base_query = Category.all
        case @current_scope
        when 'top_level' then base_query = Category.top_level
        when 'top'       then base_query = Category.top
        when 'custom'    then base_query = Category.custom
        when 'popular'   then base_query = Category.popular
        when 'active'    then base_query = Category.active
        end

        categories = base_query.with_attached_icon
                             .with_attached_pictogram
                             .order(:name)
                             .to_a
        
        Category.build_tree(categories)
      end
      
      @filters_reindex_task = ParserTask.by_type('category_filters').recent.first
      @filters_reindex_running = ParserTask.by_type('category_filters').where(status: ['running', 'pending']).exists?
      
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
      result = Categories::ProductImportService.new(@category, file).call
      if result.error_message
        flash[:error] = result.error_message
      else
        msg = "Импортировано #{result.imported} товаров."
        msg += " Пропущено #{result.skipped} SKU (не найдены в базе)." if result.skipped > 0
        flash[:notice] = msg
        flash[:warning] = "Не найдены SKU: #{result.skipped_skus.join(', ')}" if result.skipped > 0
      end
      redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
    end

    def add_product
      @category = admin.find_instance(params)
      sku = params[:sku].to_s.strip
      product = Product.find_by(sku: sku)
      if product
        if @category.category_products.exists?(product_id: product.id)
          flash[:error] = "Товар с SKU #{sku} уже есть в этой категории."
        else
          @category.category_products.create(product: product)
          flash[:notice] = "Товар #{product.name_ru || product.name} добавлен."
        end
      else
        flash[:error] = "Товар с SKU #{sku} не найден в базе."
      end
      redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
    end

    def remove_product
      @category = admin.find_instance(params)
      cp = @category.category_products.find_by(product_id: params[:product_id])
      if cp
        cp.destroy
        flash[:notice] = "Товар удален из категории."
      else
        flash[:error] = "Связь не найдена."
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
      Rails.cache.delete_matched("categories_tree_*")
      Rails.cache.delete("categories_product_counts")
      Rails.cache.delete("categories_children_counts")
      Rails.cache.delete("categories_max_updated_at")
      Rails.cache.delete_matched("category_*_children_count")
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
    post :add_product, on: :member
    post :remove_product, on: :member
  end

  table do
    column :ikea_id, label: "IKEA ID"
    column :translated_name, label: "Название (RU)"
    column :name, label: "Название (PL)", link: true
    column :is_popular, label: "Популярная" do |category|
      status_tag(category.is_popular? ? 'Да' : 'Нет', category.is_popular? ? :success : :secondary)
    end
    column :is_deleted, label: "Статус" do |category|
      status_tag(category.is_deleted? ? 'Отключена' : 'Активна', category.is_deleted? ? :danger : :success)
    end
    column :products_count, label: "Товаров" do |category|
      product_counts = instance_variable_get(:@_product_counts_cache)
      unless product_counts
        product_counts = Rails.cache.fetch("categories_product_counts", expires_in: 30.minutes) do
          CategoryProduct.select(:category_id).group(:category_id).count
        end
      end
      product_counts[category.ikea_id] || 0
    end
    column :created_at, label: "Создана", align: :center
    actions
  end

  form do |category|
    tab :basic, label: "Основная информация" do
      if category.persisted?
        text_field :ikea_id, readonly: true, label: "IKEA ID"
      else
        text_field :ikea_id, label: "IKEA ID"
      end
    
      text_field :name, label: "Название (оригинальное)"
      text_field :translated_name, label: "Название (перевод)"
      
      divider
      
      row do
        col(sm: 6) { number_field :delivery_days, label: "Срок доставки", help: "В днях. Если не задано, используется значение по умолчанию" }
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
                image_tag(icon_path, style: "max-width: 80px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;", id: "current-icon-preview")
              end
            end
            content << content_tag(:div, id: "new-icon-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "icon-preview", style: "max-width: 80px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;")
            end
            content.html_safe
          end)
          file_field :icon, label: "Иконка (PNG, WebP)"
        end

        col(sm: 4) do
          h4 "Пиктограмма"
          concat(content_tag(:div, id: "category-pictogram-preview-container", style: "margin-bottom: 15px;") do
            content = +""
            if category.persisted? && category.pictogram.attached?
              pic_path = main_app.rails_storage_proxy_path(category.pictogram, only_path: true)
              content << content_tag(:div, class: "current-pictogram-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px; display: inline-block;") do
                image_tag(pic_path, style: "max-width: 80px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;", id: "current-pictogram-preview")
              end
            end
            content << content_tag(:div, id: "new-pictogram-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "pictogram-preview", style: "max-width: 80px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;")
            end
            content.html_safe
          end)
          file_field :pictogram, label: "Пиктограмма (SVG)"
          if category.pictogram.attached?
            static_field :pictogram_url, label: "URL пиктограммы" do
              main_app.rails_storage_proxy_path(category.pictogram, only_path: true)
            end
          end
        end

        col(sm: 4) do
          h4 "Фон"
          concat(content_tag(:div, id: "category-bg-preview-container", style: "margin-bottom: 15px;") do
            content = +""
            if category.persisted? && category.background_image.attached?
              bg_path = main_app.rails_storage_proxy_path(category.background_image, only_path: true)
              content << content_tag(:div, class: "current-bg-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px; display: inline-block;") do
                image_tag(bg_path, style: "max-width: 150px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;", id: "current-bg-preview")
              end
            end
            content << content_tag(:div, id: "new-bg-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "bg-preview", style: "max-width: 150px; max-height: 80px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;")
            end
            content.html_safe
          end)
          file_field :background_image, label: "Фон (спецпредложение)"
        end
      end
      
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
              setupPreview('pictogram', 'pictogram-preview', 'new-pictogram-preview', 'current-pictogram-preview');
              setupPreview('background_image', 'bg-preview', 'new-bg-preview', 'current-bg-preview');
            }
            document.addEventListener('turbo:load', initPreviews);
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', initPreviews);
            } else { initPreviews(); }
          })();
        JS
      end)

      divider 
      h3 "Отображение блоков"
      divider 
      row do
        col(sm: 6) { check_box :is_bulky, label: "Крупногабаритный товар" }
        col(sm: 6) { check_box :show_delivery_block, label: "Показывать доставку" }
      end
      row do
        col(sm: 6) { check_box :show_reviews_block, label: "Показывать отзывы" }
        col(sm: 6) { check_box :show_tips_block, label: "Показывать советы" }
      end
    end

    tab :products, label: "Товары" do
      if category.persisted?
        h4 "Добавить товар вручную"
        render inline: <<-ERB, locals: { category: category, admin: admin }
          <%= form_tag admin.path(:add_product, id: category.ikea_id), method: :post do %>
            <div class="input-group" style="margin-bottom: 20px;">
              <%= text_field_tag :sku, nil, placeholder: "Введите SKU товара (например, 102.456.32)", class: "form-control" %>
              <span class="input-group-btn">
                <%= submit_tag "Добавить", class: "btn btn-success" %>
              </span>
            </div>
          <% end %>
        ERB
        divider
        h4 "Импорт товаров (CSV)"
        render inline: <<-ERB, locals: { category: category, admin: admin }
          <%= form_tag admin.path(:import_products_csv, id: category.ikea_id), method: :post, multipart: true do %>
            <div class="input-group" style="margin-bottom: 10px;">
              <%= file_field_tag :file, accept: ".csv", class: "form-control" %>
              <span class="input-group-btn">
                <%= submit_tag "Загрузить CSV", class: "btn btn-primary" %>
              </span>
            </div>
            <p class="help-block">Один SKU на строку. Текущий список товаров будет заменен.</p>
          <% end %>
        ERB
        divider
        h4 "Список товаров в категории"
        table category.category_products.includes(:product), label: "Товары" do
          column :sku do |cp|
            cp.product.sku
          end
          column :name do |cp|
            link_to cp.product.name_ru || cp.product.name, admin_url_for(cp.product) rescue (cp.product.name_ru || cp.product.name)
          end
          column :price do |cp|
            cp.product.price
          end
          column :actions, header: false do |cp|
            link_to "Удалить", admin.path(:remove_product, id: category.ikea_id, product_id: cp.product_id), 
                    method: :post, class: "btn btn-danger btn-xs", 
                    data: { confirm: "Вы уверены, что хотите удалить этот товар из категории?" }
          end
        end
      else
        row { col { content_tag(:p, "Сохраните категорию, чтобы управлять списком товаров.", class: "alert alert-info") } }
      end
    end

    tab :seo, label: "SEO" do
      seo_obj = category.seo_meta || category.build_seo_meta
      fields_for :seo_meta, seo_obj do |seo|
        row { col(sm: 12) { seo.text_field :title, label: "SEO Title", help: "Если пусто, будет сгенерировано автоматически" } }
        row { col(sm: 12) { seo.text_area :description, label: "SEO Description", help: "Если пусто, будет сгенерировано автоматически" } }
        row do
          col(sm: 6) { seo.text_field :keywords, label: "SEO Keywords" }
          col(sm: 6) { seo.text_field :robots, label: "SEO Robots", placeholder: "index, follow" }
        end
        row { col(sm: 12) { seo.tinymce :seo_text, label: "SEO Текст" } }
      end
    end

    sidebar do
      form_group :status, label: "Статус и настройки" do
        check_box :is_deleted, label: "Категория удалена (скрыта)"
        check_box :is_popular, label: "Популярная категория"
        check_box :is_top, label: "ТОП-категория"
        number_field :top_position, label: "Позиция в ТОП"
        check_box :is_custom, label: "Кастомная (Спецпредложение)"
      end
      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата обновления"
      end
    end
  end

  params do |params|
    params.require(:category).permit(
      :ikea_id, :name, :translated_name, :is_popular, :is_top, :top_position, :is_custom, :default_sort,
      :header_menu, :is_deleted, :header_menu_position, :delivery_days,
      :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
      :icon, :pictogram, :background_image,
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end
