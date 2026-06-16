# frozen_string_literal: true

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
      @current_scope = params[:scope] || "all"

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
        base_query =
          case @current_scope
          when "top_level" then Category.top_level
          when "top"       then Category.top
          when "custom"    then Category.custom
          when "popular"   then Category.popular
          when "active"    then Category.active
          else Category.all
          end
      
        categories = base_query.with_attached_icon
                               .with_attached_pictogram
                               .to_a
      
        Category.build_tree(categories, sort_roots_by_position: true)
      end

      @filters_reindex_task = ParserTask.by_type("category_filters").recent.first
      @filters_reindex_running = ParserTask.by_type("category_filters").where(status: %w[running pending]).exists?

      render "trestle/categories/index"
    end

    def new
      @category = Category.new(params[:category]&.to_unsafe_h || {})
      @category.ikea_id ||= "custom-#{SecureRandom.hex(4)}" if @category.is_custom?
      @category.parent_ikea_id = @category.current_parent_ikea_id
    end

    def edit
      @category = admin.find_instance(params)
      @category.parent_ikea_id = @category.current_parent_ikea_id
    end

    def create
      category_params = admin.permitted_params(params)
      new_parent_ikea_id = category_params.delete(:parent_ikea_id).presence

      @category = Category.new(category_params)
      @category.parent_ikea_id = new_parent_ikea_id

      if @category.invalid?
        flash.now[:error] = @category.errors.full_messages.to_sentence
        return render :new, status: :unprocessable_entity
      end

      Category.transaction do
        @category.save!

        if new_parent_ikea_id.present?
          new_parent = Category.unscoped.find_by!(ikea_id: new_parent_ikea_id.to_s)

          Categories::MoveNodeService.new(
            moved_category: @category,
            new_parent_category: new_parent,
            actor: try(:current_user)
          ).call
        end
      end

      clear_categories_cache
      redirect_to admin.path(:show, id: @category), notice: "Категория создана"
    rescue Categories::MoveNodeService::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @category.parent_ikea_id = new_parent_ikea_id
      flash.now[:error] = e.message
      render :new, status: :unprocessable_entity
    end

    def update
      @category = admin.find_instance(params)
      category_params = admin.permitted_params(params)
      new_parent_ikea_id = category_params.delete(:parent_ikea_id).presence
      old_parent_ikea_id = @category.current_parent_ikea_id

      @category.assign_attributes(category_params)
      @category.parent_ikea_id = new_parent_ikea_id

      if @category.invalid?
        flash.now[:error] = @category.errors.full_messages.to_sentence
        return render :edit, status: :unprocessable_entity
      end

      Category.transaction do
        @category.save!

        if new_parent_ikea_id.to_s != old_parent_ikea_id.to_s
          new_parent = new_parent_ikea_id.present? ? Category.unscoped.find_by!(ikea_id: new_parent_ikea_id.to_s) : nil

          Categories::MoveNodeService.new(
            moved_category: @category,
            new_parent_category: new_parent,
            actor: try(:current_user)
          ).call
        end
      end

      clear_categories_cache
      redirect_to admin.path(:show, id: @category), notice: "Категория обновлена"
    rescue Categories::MoveNodeService::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @category.parent_ikea_id = new_parent_ikea_id
      flash.now[:error] = e.message
      render :edit, status: :unprocessable_entity
    end

    def move_node
      moved = Category.unscoped.find_by!(ikea_id: params[:moved_id].to_s)
      new_parent = params[:new_parent_id].present? ? Category.unscoped.find_by!(ikea_id: params[:new_parent_id].to_s) : nil

      result = Categories::MoveNodeService.new(
        moved_category: moved,
        new_parent_category: new_parent,
        actor: try(:current_user)
      ).call

      clear_categories_cache

      render json: {
        ok: true,
        moved_id: moved.ikea_id.to_s,
        new_parent_id: new_parent&.ikea_id&.to_s,
        updated_ids: result.updated_ids
      }, status: :ok
    rescue Categories::MoveNodeService::Error, ActiveRecord::RecordNotFound => e
      render json: { ok: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("categories#move_node failed: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      render json: { ok: false, error: "Внутренняя ошибка при перемещении категории" }, status: :internal_server_error
    end

    def toggle_top
      @category = admin.find_instance(params)
      @category.update(is_top: !@category.is_top)
      clear_categories_cache
      redirect_to "/admin/categories", notice: "Категория #{@category.is_top? ? 'добавлена в ТОП' : 'удалена из ТОП'}"
    end

    def toggle_custom
      @category = admin.find_instance(params)
      @category.update(is_custom: !@category.is_custom)
      clear_categories_cache
      redirect_to "/admin/categories", notice: "Категория #{@category.is_custom? ? 'сделана кастомной' : 'сделана обычной'}"
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
          flash[:notice] = "Товар #{product.name.presence || product.sku} добавлен."
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

    def reassign_products
      @category = admin.find_instance(params)
      target_id = params[:target_category_id].to_s.strip

      if target_id.blank?
        flash[:error] = "Выберите целевую категорию."
        return redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
      end

      if target_id.to_s == @category.ikea_id.to_s
        flash[:error] = "Целевая категория должна отличаться от исходной."
        return redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
      end

      target_category = Category.unscoped.find_by(ikea_id: target_id)
      unless target_category
        flash[:error] = "Целевая категория не найдена."
        return redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
      end

      source_category_id = @category.ikea_id.to_s
      target_category_id = target_category.ikea_id.to_s

      source_product_ids = CategoryProduct.where(category_id: source_category_id).pluck(:product_id)
      if source_product_ids.empty?
        flash[:warning] = "В исходной категории нет товаров для переноса."
        return redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
      end

      existing_target_ids = CategoryProduct.where(
        category_id: target_category_id,
        product_id: source_product_ids
      ).pluck(:product_id)

      to_add_ids = source_product_ids - existing_target_ids

      CategoryProduct.transaction do
        if to_add_ids.any?
          now = Time.current
          rows = to_add_ids.map do |product_id|
            { category_id: target_category_id, product_id: product_id, created_at: now, updated_at: now }
          end

          CategoryProduct.insert_all(rows)
        end

        CategoryProduct.where(category_id: source_category_id, product_id: source_product_ids).delete_all
      end

      delete_source = params[:delete_source] == "1"
      message = "Товары перенесены (#{to_add_ids.size} добавлено, #{existing_target_ids.size} уже было)."

      if delete_source
        @category.destroy
        message += " Исходная категория удалена."
      end

      clear_categories_cache

      respond_to do |format|
        format.json do
          redirect_to =
            if delete_source
              admin.path(:edit, id: target_category_id)
            else
              admin.path(:edit, id: @category.ikea_id)
            end
          render json: {
            ok: true,
            added: to_add_ids.size,
            existed: existing_target_ids.size,
            redirect_to: redirect_to,
            message: message
          }, status: :ok
        end
        format.html do
          flash[:notice] = message
          redirect_to admin.path(:edit, id: (delete_source ? target_category_id : @category.ikea_id))
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      flash[:error] = "Ошибка переноса: #{e.message}"
      redirect_back fallback_location: edit_categories_admin_path(@category.ikea_id)
    end

    def show
      @category = admin.find_instance(params)
      scope =
        Product
          .in_category_ikea_id(@category.ikea_id)
          .order(:id)

      page = params[:products_page]
      paginated = scope.page(page).per(20)
      # При переходах между категориями в URL может оставаться products_page,
      # который выходит за диапазон для текущей категории.
      paginated = scope.page(1).per(20) if paginated.out_of_range? && paginated.total_pages.positive?

      @paginated_category_products = paginated
      render "trestle/categories/show"
    end

    def toggle_active
      @category = admin.find_instance(params)
      @category.update(is_deleted: !@category.is_deleted)
      clear_categories_cache
      redirect_to "/admin/categories", notice: "Категория #{@category.is_deleted? ? 'отключена' : 'включена'}"
    end

    def toggle_popular
      @category = admin.find_instance(params)
      attrs = { is_popular: !@category.is_popular }

      if attrs[:is_popular] && @category.popular_position.to_i <= 0
        attrs[:popular_position] = Category.where(is_popular: true).maximum(:popular_position).to_i + 1
      end

      @category.update(attrs)
      clear_categories_cache
      redirect_to "/admin/categories", notice: "Категория #{@category.is_popular? ? 'добавлена в популярные' : 'удалена из популярных'}"
    end

    def soft_delete
      @category = admin.find_instance(params)
      @category.update(is_deleted: true)
      clear_categories_cache
      redirect_to "/admin/categories", notice: "Категория отключена (мягкое удаление)"
    end

    def reindex_filters
      @category = admin.find_instance(params)
      ReindexCategoryFiltersJob.perform_later(@category.ikea_id)
      redirect_back fallback_location: admin.path(:index),
                    notice: "Запущена переиндексация фильтров для категории #{@category.ikea_id}."
    end

    def reindex_all_filters
      if ParserTask.by_type("category_filters").where(status: %w[running pending]).exists?
        redirect_to admin.path(:index), alert: "Переиндексация фильтров уже запущена."
        return
      end

      task = ParserTask.create!(task_type: "category_filters", status: "pending")
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
    post :reassign_products, on: :member
    post :move_node, on: :collection
  end

  table do
    column :ikea_id
    column :translated_name
    column :name, link: true

    column :is_popular do |category|
      status_tag(category.is_popular? ? "Да" : "Нет", category.is_popular? ? :success : :secondary)
    end

    column :popular_position, header: "Позиция популярной"

    column :is_deleted do |category|
      status_tag(category.is_deleted? ? "Отключена" : "Активна", category.is_deleted? ? :danger : :success)
    end

    column :products_count do |category|
      product_counts = instance_variable_get(:@_product_counts_cache)

      unless product_counts
        product_counts = Rails.cache.fetch("categories_product_counts", expires_in: 30.minutes) do
          CategoryProduct.select(:category_id).group(:category_id).count
        end
      end

      product_counts[category.ikea_id] || 0
    end

    column :created_at, align: :center
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

      if category.current_parent_ikea_id.present?
        parent_category = Category.find_by(ikea_id: category.current_parent_ikea_id.to_s)
        parent_label = if parent_category
                         "#{parent_category.translated_name.presence || parent_category.name} (#{parent_category.ikea_id})"
                       else
                         category.current_parent_ikea_id.to_s
                       end
        row do
          col(sm: 12) do
            static_field :current_parent, label: "Текущая родительская категория" do
              if parent_category
                link_to(parent_label, admin.instance_path(parent_category))
              else
                content_tag(:span, parent_label, class: "text-muted")
              end
            end
          end
        end

        divider
      end

      excluded_ids = [category.ikea_id.to_s]
      if category.persisted? && category.ikea_id.present?
        excluded_ids.concat(category.descendant_ikea_ids)
      end

      parent_options = Category.order(:translated_name).pluck(:translated_name, :ikea_id).reject do |_, ikea_id|
        excluded_ids.include?(ikea_id.to_s)
      end

      selected_parent_id = category.parent_ikea_id.presence || category.current_parent_ikea_id

      parent_options = Category.order(:translated_name).map do |c|
        ["#{c.translated_name.presence || c.name} (#{c.ikea_id})", c.ikea_id.to_s]
      end.reject do |_, ikea_id|
        excluded_ids.include?(ikea_id.to_s)
      end

      select :parent_ikea_id,
             parent_options,
             {
               include_blank: "Без родителя (верхний уровень)",
               selected: selected_parent_id.to_s
             },
             label: "Родительская категория",
             class: "trestle-parent-category-select",
             help: "Нельзя выбрать саму категорию или любую из ее дочерних категорий."

      divider

      row do
        col(sm: 6) do
          number_field :delivery_days, label: "Срок доставки", help: "В днях. Если не задано, используется значение по умолчанию"
        end
      end

      divider
      h3 "Изображения категории"
      content_tag :p, "Растровые изображения (icon/background) автоматически конвертируются в WebP и сжимаются до ~200KB при сохранении.", class: "text-muted"
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
            function initCategoryForm() {
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

              var parentSelect = document.querySelector('.trestle-parent-category-select');
              if (parentSelect && window.jQuery && window.jQuery.fn.select2) {
                var $parentSelect = window.jQuery(parentSelect);

                if ($parentSelect.data('select2')) {
                  $parentSelect.select2('destroy');
                }

                $parentSelect.select2({
                  width: '100%',
                  placeholder: 'Выберите родительскую категорию',
                  allowClear: true
                });
              }

              var reassignSelect = document.querySelector('.trestle-reassign-category-select');
              if (reassignSelect && window.jQuery && window.jQuery.fn.select2) {
                var $reassignSelect = window.jQuery(reassignSelect);

                if ($reassignSelect.data('select2')) {
                  $reassignSelect.select2('destroy');
                }

                $reassignSelect.select2({
                  width: '100%',
                  placeholder: 'Выберите целевую категорию',
                  allowClear: true
                });
              }

              var reassignContainer = document.querySelector('.trestle-reassign-products');
              if (reassignContainer) {
                var reassignButton = reassignContainer.querySelector('.trestle-reassign-button');
                var reassignDelete = reassignContainer.querySelector('.trestle-reassign-delete-source');
                var reassignSelectEl = reassignContainer.querySelector('.trestle-reassign-category-select');
                var reassignUrl = reassignContainer.dataset.reassignUrl;
                var sourceId = reassignContainer.dataset.sourceId;

                if (reassignButton) {
                  reassignButton.addEventListener('click', function() {
                    var targetId = reassignSelectEl ? reassignSelectEl.value : "";
                    if (!targetId) {
                      alert("Выберите целевую категорию.");
                      return;
                    }

                    var confirmText = reassignButton.dataset.confirm || "Перенести все товары в выбранную категорию?";
                    if (!confirm(confirmText)) return;

                    var csrf = document.querySelector('meta[name="csrf-token"]');
                    var params = new URLSearchParams();
                    params.append('target_category_id', targetId);
                    if (reassignDelete && reassignDelete.checked) {
                      params.append('delete_source', '1');
                    }

                    reassignButton.disabled = true;
                    reassignButton.textContent = "Переносим...";

                    fetch(reassignUrl, {
                      method: 'POST',
                      headers: {
                        'Accept': 'application/json',
                        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                        'X-CSRF-Token': csrf ? csrf.content : ''
                      },
                      body: params.toString()
                    }).then(function(resp) {
                      if (!resp.ok) throw new Error('Request failed');
                      return resp.json();
                    }).then(function(data) {
                      if (data && data.redirect_to) {
                        window.location = data.redirect_to;
                      } else {
                        window.location = window.location.href;
                      }
                    }).catch(function() {
                      alert("Ошибка переноса. Проверьте логи.");
                    }).finally(function() {
                      reassignButton.disabled = false;
                      reassignButton.textContent = "Перепривязать товары";
                    });
                  });
                }
              }
            }

            document.addEventListener('turbo:load', initCategoryForm);
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', initCategoryForm);
            } else {
              initCategoryForm();
            }
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
        h4 "Массовая перепривязка товаров"
        render inline: <<-'ERB', locals: { category: category, admin: admin }
          <% reassign_options = Category.order(:translated_name).where.not(ikea_id: category.ikea_id).map do |c|
               ["#{c.translated_name.presence || c.name} (#{c.ikea_id})", c.ikea_id]
             end %>
          <div class="trestle-reassign-products"
               data-reassign-url="<%= admin.path(:reassign_products, id: category.ikea_id) %>"
               data-source-id="<%= category.ikea_id %>">
            <div class="row" style="margin-bottom: 10px;">
              <div class="col-sm-8">
                <%= select_tag :target_category_id,
                      options_for_select(reassign_options),
                      include_blank: "Выберите целевую категорию",
                      class: "form-control trestle-reassign-category-select" %>
              </div>
              <div class="col-sm-4">
                <div class="checkbox" style="margin-top: 6px;">
                  <label>
                    <%= check_box_tag :delete_source, "1", false, class: "trestle-reassign-delete-source" %>
                    Удалить исходную после переноса
                  </label>
                </div>
              </div>
            </div>
            <p class="help-block">Переносит все товары из текущей категории в выбранную. Дубли не создаются.</p>
            <button type="button"
                    class="btn btn-warning trestle-reassign-button"
                    data-confirm="Перенести все товары в выбранную категорию?">
              Перепривязать товары
            </button>
          </div>
        ERB

        divider
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
            name = cp.product&.name.presence || cp.product&.sku
            extra = cp.product&.small_desc_name.to_s.strip
            label = extra.present? ? "#{name} — #{extra}" : name
            if cp.product
              link_to(label, Trestle.lookup(:products).path(:show, id: cp.product.id), data: { turbo: false })
            else
              label || "—"
            end
          end

          column :price do |cp|
            cp.product.price
          end

          column :actions, header: false do |cp|
            link_to "Удалить",
                    admin.path(:remove_product, id: category.ikea_id, product_id: cp.product_id),
                    method: :post,
                    class: "btn btn-danger btn-xs",
                    data: { confirm: "Вы уверены, что хотите удалить этот товар из категории?" }
          end
        end
      else
        row { col { content_tag(:p, "Сохраните категорию, чтобы управлять списком товаров.", class: "alert alert-info") } }
      end
    end

    tab :filters, label: "Фильтры" do
      if category.persisted?
        filters = category.available_filters

        h4 "Фильтры категории"

        if filters.present?
          static_field :available_filters_json, label: "JSON" do
            content_tag(
              :pre,
              JSON.pretty_generate(filters),
              style: "max-height: 700px; overflow:auto; background:#f8f9fa; padding:15px; border:1px solid #ddd; border-radius:6px; font-size:12px; line-height:1.45;"
            )
          end
        else
          row do
            col do
              content_tag(:p, "У этой категории фильтры отсутствуют.", class: "alert alert-info")
            end
          end
        end
      else
        row do
          col do
            content_tag(:p, "Сначала сохраните категорию, затем можно посмотреть фильтры.", class: "alert alert-info")
          end
        end
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
        row { col(sm: 12) { seo.text_field :h1, label: "H1", help: "Если пусто — из глобального шаблона категорий" } }
      end
    end

    sidebar do
      form_group :status, label: "Статус и настройки" do
        check_box :is_deleted, label: "Категория удалена (скрыта)"
        check_box :is_popular, label: "Популярная категория"
        number_field :popular_position,
               label: "Позиция в популярных",
               help: "Используется для блока «Популярные категории». Чем меньше число, тем выше категория."
        check_box :is_top, label: "ТОП-категория"
        number_field :top_position, label: "Позиция в ТОП"
        number_field :root_position,
               label: "Позиция верхнего уровня",
               help: "Используется только для категорий 1-го уровня. Чем меньше число, тем выше категория."
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
      :ikea_id,
      :name,
      :translated_name,
      :is_popular,
      :popular_position,
      :is_top,
      :top_position,
      :root_position,
      :is_custom,
      :default_sort,
      :header_menu,
      :is_deleted,
      :header_menu_position,
      :delivery_days,
      :is_bulky,
      :show_delivery_block,
      :show_reviews_block,
      :show_tips_block,
      :icon,
      :pictogram,
      :background_image,
      :parent_ikea_id,
      seo_meta_attributes: [:id, :title, :description, :keywords, :robots, :seo_text, :h1, :_destroy]
    )
  end
end
