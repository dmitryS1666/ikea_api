# frozen_string_literal: true

module Categories
  class MoveNodeService
    class Error < StandardError; end

    Result = Struct.new(:moved_category, :updated_ids, :old_parent_ids, :new_parent_ids, keyword_init: true)

    def initialize(moved_category:, new_parent_category: nil, actor: nil)
      @moved_category = moved_category
      @new_parent_category = new_parent_category
      @actor = actor
    end

    def call
      validate!

      old_parent_ids = Category.normalize_parent_ids(@moved_category.parent_ids).map(&:to_s)
      new_parent_ids = desired_parent_ids
      return Result.new(moved_category: @moved_category, updated_ids: [], old_parent_ids: old_parent_ids, new_parent_ids: new_parent_ids) if old_parent_ids == new_parent_ids

      updated_ids = []
      old_self_path = old_parent_ids + [@moved_category.ikea_id.to_s]
      new_self_path = new_parent_ids + [@moved_category.ikea_id.to_s]

      ActiveRecord::Base.transaction do
        affected = affected_categories.lock.to_a

        @moved_category.parent_ids = new_parent_ids
        @moved_category.is_important = new_parent_ids.empty? if @moved_category.respond_to?(:is_important=)
        @moved_category.save!
        updated_ids << @moved_category.ikea_id.to_s

        affected.each do |category|
          next if category.ikea_id.to_s == @moved_category.ikea_id.to_s

          current_path = Category.normalize_parent_ids(category.parent_ids).map(&:to_s)
          next unless starts_with_path?(current_path, old_self_path)

          suffix = current_path.drop(old_self_path.length)
          category.parent_ids = new_self_path + suffix
          category.is_important = false if category.respond_to?(:is_important=)
          category.save!
          updated_ids << category.ikea_id.to_s
        end
      end

      invalidate_caches!(updated_ids + [@new_parent_category&.ikea_id&.to_s].compact)

      Result.new(
        moved_category: @moved_category.reload,
        updated_ids: updated_ids.uniq,
        old_parent_ids: old_parent_ids,
        new_parent_ids: new_parent_ids
      )
    end

    private

    def desired_parent_ids
      return [] unless @new_parent_category

      Category.normalize_parent_ids(@new_parent_category.parent_ids).map(&:to_s) + [@new_parent_category.ikea_id.to_s]
    end

    def validate!
      raise Error, 'Категория для перемещения не найдена' unless @moved_category
      return unless @new_parent_category

      if @moved_category.ikea_id.to_s == @new_parent_category.ikea_id.to_s
        raise Error, 'Нельзя переместить категорию в саму себя'
      end

      new_parent_path = Category.normalize_parent_ids(@new_parent_category.parent_ids).map(&:to_s)
      if new_parent_path.include?(@moved_category.ikea_id.to_s)
        raise Error, 'Нельзя переместить категорию в собственного потомка'
      end

      raise Error, 'Нельзя перемещать категорию в отключенную категорию' if @new_parent_category.is_deleted?
    end

    def affected_categories
      moved_id = @moved_category.ikea_id.to_s
      Category.unscoped.where(
        "ikea_id = :moved_id OR parent_ids::text LIKE :quoted",
        moved_id: moved_id,
        quoted: "%\"#{moved_id}\"%"
      )
    end

    def starts_with_path?(full_path, prefix)
      full_path.first(prefix.length) == prefix
    end

    def invalidate_caches!(ids)
      Rails.cache.delete_matched('categories_tree_*') if Rails.cache.respond_to?(:delete_matched)
      Rails.cache.delete('categories_product_counts')
      Rails.cache.delete('categories_children_counts')
      Rails.cache.delete('categories_max_updated_at')
      ids.uniq.each { |id| Rails.cache.delete("category_#{id}_children_count") }
    rescue => e
      Rails.logger.warn("MoveNodeService cache clear failed: #{e.class} #{e.message}")
    end
  end
end
