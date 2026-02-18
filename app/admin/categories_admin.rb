Trestle.resource(:categories, model: Category) do
  menu do
    item :categories, icon: "fa fa-folder", priority: 1, label: "Категории", group: "Catalog"
  end

  scopes do
    scope :all, default: true
    scope :top_level, -> { Category.top_level }, label: "Верхнеуровневые"
    scope :popular, -> { Category.popular }, label: "Популярные"
    scope :active, -> { Category.active }, label: "Активные"
    scope :in_header_menu, -> { Category.in_header_menu }, label: "В хедере"
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
        when 'popular'
          base_query = Category.popular
        when 'active'
          base_query = Category.active
        when 'in_header_menu'
          base_query = Category.in_header_menu
        end

        # Дерево категорий без кэша
        categories = base_query.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_deleted, :is_important, :header_menu, :header_menu_position)
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
          when 'popular'
            base_query = Category.popular
          when 'active'
            base_query = Category.active
          when 'in_header_menu'
            base_query = Category.in_header_menu
          end

          # Оптимизированный запрос - загружаем только нужные поля
          categories = base_query.select(:ikea_id, :name, :translated_name, :parent_ids, :is_popular, :is_deleted, :is_important, :header_menu, :header_menu_position)
                               .order(:name)
                               .to_a
          tree = Category.build_tree(categories)
          Rails.logger.info "CategoriesAdmin: Built tree with #{tree.count} top-level categories (scope: #{@current_scope})"
          tree
        end
      end
      
      Rails.logger.info "CategoriesAdmin: Rendering tree with #{@categories_tree.count} top-level categories"
      render "trestle/categories/index"
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
        :ikea_id, :name, :translated_name, :is_popular, :default_sort, 
        :header_menu, :is_deleted, :header_menu_position, :delivery_days,
        :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
        :icon
      )
    end
  end

  params do |params|
    params.require(:category).permit(
      :ikea_id, :name, :translated_name, :is_popular, :default_sort, 
      :header_menu, :is_deleted, :header_menu_position, :delivery_days,
      :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
      :icon
    )
  end

  routes do
    post :toggle_active, on: :member
    post :toggle_popular, on: :member
    post :soft_delete, on: :member
  end

  table do
    column :ikea_id
    column :translated_name 
    column :name, link: true
    column :is_popular do |category|
      status_tag(category.is_popular? ? 'Да' : 'Нет', 
                 category.is_popular? ? :success : :secondary)
    end
    column :header_menu, label: "В хедере" do |category|
      status_tag(category.header_menu? ? 'Да' : 'Нет', 
                 category.header_menu? ? :success : :secondary)
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
      check_box :is_popular
      select :default_sort, Category.default_sorts.keys.map { |s| [s.humanize, s] }
      check_box :header_menu
      check_box :is_deleted
      number_field :header_menu_position
      number_field :delivery_days, help: "Срок доставки в днях (если не задано, используется значение по умолчанию)"

      divider
      h3 "Иконка категории"
      divider

      row do
        col(sm: 12) do
          concat(content_tag(:div, id: "category-icon-preview-container", style: "margin-bottom: 15px;") do
            content = +""
            if category.persisted? && category.icon.attached?
              content << content_tag(:div, class: "current-icon-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px; display: inline-block;") do
                image_tag(Rails.application.routes.url_helpers.rails_blob_path(category.icon, only_path: true),
                        style: "max-width: 100px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;",
                        id: "current-icon-preview") +
                content_tag(:p, "Текущая иконка", style: "text-align: center; margin-top: 10px; color: #666; font-size: 12px;")
              end
            end
            content << content_tag(:div, id: "new-icon-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px; display: inline-block;") do
              content_tag(:img, "", id: "icon-preview", style: "max-width: 100px; max-height: 100px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;") +
              content_tag(:p, "Предпросмотр новой иконки", style: "text-align: center; margin-top: 10px; color: #2e7d32; font-size: 12px; font-weight: bold;")
            end
            content.html_safe
          end)

          file_field :icon, label: "Иконка (SVG, PNG, WebP)"
          
          # JavaScript для предпросмотра иконки
          concat(content_tag(:script, type: "text/javascript") do
            raw <<-JS.strip_heredoc
              (function() {
                function initIconPreview() {
                  var fileInput = document.querySelector('input[type="file"][name*="[icon]"]');
                  if (!fileInput) return;

                  var preview = document.getElementById('icon-preview');
                  var container = document.getElementById('new-icon-preview');
                  var currentPreview = document.querySelector('.current-icon-preview');

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

                document.addEventListener('turbo:load', initIconPreview);
                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', initIconPreview);
                } else {
                  initIconPreview();
                }
              })();
            JS
          end)
        end
      end

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
      :ikea_id, :name, :translated_name, :is_popular, :default_sort,
      :header_menu, :is_deleted, :header_menu_position, :delivery_days,
      :is_bulky, :show_delivery_block, :show_reviews_block, :show_tips_block,
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :_destroy]
    )
  end
end
