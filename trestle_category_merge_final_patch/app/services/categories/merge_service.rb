# frozen_string_literal: true

module Categories
  class MergeService
    class Error < StandardError; end

    Result = Struct.new(:source_category, :target_category, :stats, keyword_init: true)

    def initialize(source_category:, target_category:, actor: nil, soft_delete_source: true)
      @source_category = source_category
      @target_category = target_category
      @actor = actor
      @soft_delete_source = soft_delete_source
      @stats = Hash.new(0)
    end

    def call
      validate!

      old_source_path = normalized_path(@source_category.parent_ids) + [@source_category.ikea_id.to_s]
      target_path = normalized_path(@target_category.parent_ids) + [@target_category.ikea_id.to_s]

      ActiveRecord::Base.transaction do
        reassign_legacy_products!
        reassign_category_products!
        reassign_product_filter_values!
        reassign_simple_relations!
        rewrite_content_article_body_blocks!
        move_source_children!(old_source_path, target_path)
        soft_delete_source! if @soft_delete_source
      end

      invalidate_caches!

      Result.new(source_category: @source_category.reload, target_category: @target_category.reload, stats: @stats)
    end

    private

    def validate!
      raise Error, 'Категория-источник не найдена' unless @source_category
      raise Error, 'Категория-назначение не найдена' unless @target_category

      if @source_category.ikea_id.to_s == @target_category.ikea_id.to_s
        raise Error, 'Нельзя слить категорию саму в себя'
      end

      raise Error, 'Нельзя сливать в отключенную категорию' if @target_category.is_deleted?

      target_parent_ids = normalized_path(@target_category.parent_ids)
      if target_parent_ids.include?(@source_category.ikea_id.to_s)
        raise Error, 'Нельзя сливать категорию в собственного потомка'
      end
    end

    def normalized_path(value)
      Category.normalize_parent_ids(value).map(&:to_s)
    end

    def reassign_legacy_products!
      return unless Product.column_names.include?('category_id')

      scope = Product.where(category_id: @source_category.ikea_id.to_s)
      @stats[:products_legacy] = scope.count
      touch_update_all(scope, category_id: @target_category.ikea_id.to_s)
    end

    def reassign_category_products!
      source_rows = CategoryProduct.where(category_id: @source_category.ikea_id.to_s).pluck(:id, :product_id)
      return if source_rows.empty?

      existing_product_ids = CategoryProduct.where(category_id: @target_category.ikea_id.to_s, product_id: source_rows.map(&:last)).pluck(:product_id).to_set
      to_insert = []
      to_delete_ids = []

      source_rows.each do |row_id, product_id|
        if existing_product_ids.include?(product_id)
          to_delete_ids << row_id
        else
          to_insert << { category_id: @target_category.ikea_id.to_s, product_id: product_id, created_at: Time.current, updated_at: Time.current }
          to_delete_ids << row_id
        end
      end

      CategoryProduct.insert_all(to_insert) if to_insert.any?
      CategoryProduct.where(id: to_delete_ids).delete_all if to_delete_ids.any?
      @stats[:category_products] = source_rows.size
    end

    def reassign_product_filter_values!
      return unless defined?(ProductFilterValue) && ProductFilterValue.column_names.include?('category_id')

      scope = ProductFilterValue.where(category_id: @source_category.ikea_id.to_s)
      @stats[:product_filter_values] = scope.count
      touch_update_all(scope, category_id: @target_category.ikea_id.to_s)
    end

    def reassign_simple_relations!
      reassign_if_model_exists('SeoMeta', :category_id)
      reassign_if_model_exists('HomeBanner', :category_id)
      reassign_if_model_exists('ContentArticleCategory', :category_id)
      reassign_if_model_exists('PromoCodeCategory', :category_id)
    end

    def reassign_if_model_exists(model_name, foreign_key)
      return unless Object.const_defined?(model_name)

      model = Object.const_get(model_name)
      return unless model.respond_to?(:column_names)
      return unless model.column_names.include?(foreign_key.to_s)

      scope = model.where(foreign_key => @source_category.ikea_id.to_s)
      count = scope.count
      return if count.zero?

      touch_update_all(scope, foreign_key => @target_category.ikea_id.to_s)
      @stats[model_name.underscore.to_sym] = count
    end

    def rewrite_content_article_body_blocks!
      return unless Object.const_defined?('ContentArticle')

      model = ContentArticle
      return unless model.respond_to?(:where)
      return unless model.column_names.include?('body_blocks')

      changed = 0
      model.where("body_blocks::text LIKE ?", "%#{@source_category.ikea_id}%").find_each do |article|
        blocks = article.body_blocks
        next if blocks.blank?

        rewritten = rewrite_body_blocks(blocks)
        next if rewritten == blocks

        article.update!(body_blocks: rewritten)
        changed += 1
      end

      @stats[:content_article_body_blocks] = changed if changed.positive?
    end

    def rewrite_body_blocks(blocks)
      Array.wrap(blocks).map do |block|
        next block unless block.is_a?(Hash)

        dup = block.deep_dup
        dup['button_category_id'] = @target_category.ikea_id.to_s if dup['button_category_id'].to_s == @source_category.ikea_id.to_s
        dup['slider_category_id'] = @target_category.ikea_id.to_s if dup['slider_category_id'].to_s == @source_category.ikea_id.to_s
        if dup['grid_category_ids'].is_a?(Array)
          dup['grid_category_ids'] = dup['grid_category_ids'].map { |id| id.to_s == @source_category.ikea_id.to_s ? @target_category.ikea_id.to_s : id }
        end
        dup
      end
    end

    def move_source_children!(old_source_path, target_path)
      moved_children = 0
      Category.unscoped.where("parent_ids::text LIKE ?", "%\"#{@source_category.ikea_id}\"%").find_each do |category|
        next if category.ikea_id.to_s == @source_category.ikea_id.to_s

        current_path = normalized_path(category.parent_ids)
        next unless current_path.first(old_source_path.length) == old_source_path

        suffix = current_path.drop(old_source_path.length)
        category.update!(parent_ids: target_path + suffix, is_important: false)
        moved_children += 1
      end
      @stats[:children_relinked] = moved_children if moved_children.positive?
    end

    def soft_delete_source!
      attrs = { is_deleted: true }
      attrs[:is_important] = false if @source_category.respond_to?(:is_important=)
      @source_category.update!(attrs)
      @stats[:source_soft_deleted] = 1
    end

    def touch_update_all(scope, attrs)
      attrs = attrs.merge(updated_at: Time.current) if scope.model.column_names.include?('updated_at')
      scope.update_all(attrs)
    end

    def invalidate_caches!
      Rails.cache.delete_matched('categories_tree_*') if Rails.cache.respond_to?(:delete_matched)
      Rails.cache.delete('categories_product_counts')
      Rails.cache.delete('categories_children_counts')
      Rails.cache.delete('categories_max_updated_at')
      [@source_category.ikea_id.to_s, @target_category.ikea_id.to_s].uniq.each do |id|
        Rails.cache.delete("category_#{id}_children_count")
      end
    rescue => e
      Rails.logger.warn("MergeService cache clear failed: #{e.class} #{e.message}")
    end
  end
end
