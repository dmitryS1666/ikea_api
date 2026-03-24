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

    def move_node
      moved = Category.unscoped.find_by!(ikea_id: params[:moved_id].to_s)
      new_parent = params[:new_parent_id].present? ? Category.unscoped.find_by!(ikea_id: params[:new_parent_id].to_s) : nil

      result = Categories::MoveNodeService.new(
        moved_category: moved,
        new_parent_category: new_parent,
        actor: try(:current_user)
      ).call

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

    def merge_node
      source = Category.unscoped.find_by!(ikea_id: params[:source_id].to_s)
      target = resolve_merge_target!(params[:target_id].to_s, params[:target_name].to_s)

      result = Categories::MergeService.new(
        source_category: source,
        target_category: target,
        actor: try(:current_user)
      ).call

      render json: {
        ok: true,
        source_id: source.ikea_id.to_s,
        target_id: target.ikea_id.to_s,
        stats: result.stats
      }, status: :ok
    rescue Categories::MergeService::Error, ActiveRecord::RecordNotFound => e
      render json: { ok: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("categories#merge_node failed: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      render json: { ok: false, error: "Внутренняя ошибка при merge категории" }, status: :internal_server_error
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

    def resolve_merge_target!(target_id, target_name)
      if target_id.present?
        target = Category.unscoped.find_by(ikea_id: target_id)
        return target if target
      end

      if target_name.present?
        matches = Category.unscoped.where("translated_name ILIKE ? OR name ILIKE ?", target_name, target_name).to_a
        raise Categories::MergeService::Error, "Категория назначения не найдена" if matches.empty?
        if matches.size > 1
          raise Categories::MergeService::Error, "Найдено несколько категорий назначения по имени '#{target_name}'. Укажи ikea_id."
        end
        return matches.first
      end

      raise Categories::MergeService::Error, 'Нужно указать ikea_id или точное имя категории назначения'
    end

    def clear_categories_cache
      Rails.cache.delete_matched("categories_tree_*") if Rails.cache.respond_to?(:delete_matched)
      Rails.cache.delete("categories_product_counts")
      Rails.cache.delete("categories_children_counts")
      Rails.cache.delete("categories_max_updated_at")
      Rails.cache.delete_matched("category_*_children_count") if Rails.cache.respond_to?(:delete_matched)
    end
  end

  routes do
    post :move_node, on: :collection
    post :merge_node, on: :collection
  end
end
