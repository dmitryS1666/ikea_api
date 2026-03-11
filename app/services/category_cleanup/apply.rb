module CategoryCleanup
  class Apply < Base
    def call!
      CategoryCleanupRule.for_apply.order(:source_row_no).find_each do |rule|
        ActiveRecord::Base.transaction do
          source = Category.lock.find_by!(ikea_id: rule.resolved_source_ikea_id)

          case rule.action
          when 'delete'
            soft_delete_category!(source)
          when 'merge'
            target = Category.lock.find_by!(ikea_id: rule.resolved_target_ikea_id)
            merge_categories!(source, target)
          else
            raise "Unsupported action=#{rule.action}"
          end

          rule.update!(resolution_status: 'applied')
        end
      end
    end

    private

    def merge_categories!(source, target)
      raise "Cannot merge category into itself" if source.ikea_id.to_s == target.ikea_id.to_s

      reassign_legacy_products!(source, target)
      reassign_join_products!(source, target)
      reassign_filter_values!(source, target)
      reassign_seo_meta!(source, target)
      reassign_children_parent_ids!(source, target)

      soft_delete_category!(source)
      cache_delete_for_category_ids(source.ikea_id, target.ikea_id)
    end

    def soft_delete_category!(category)
      category.update!(is_deleted: true)
      cache_delete_for_category_ids(category.ikea_id)
    end

    # products.category_id
    def reassign_legacy_products!(source, target)
      Product.where(category_id: source.ikea_id).update_all(category_id: target.ikea_id)
    end

    # category_products join table
    def reassign_join_products!(source, target)
      source_rows = CategoryProduct.where(category_id: source.ikea_id)

      source_rows.find_each do |row|
        existing = CategoryProduct.find_by(
          category_id: target.ikea_id,
          product_id: row.product_id
        )

        if existing
          row.destroy!
        else
          row.update!(category_id: target.ikea_id)
        end
      end
    end

    # product_filter_values
    # Если таблица допускает дубликаты — всё пройдет просто.
    # Если есть уникальные индексы, при конфликте удаляем дубль source.
    def reassign_filter_values!(source, target)
      ProductFilterValue.where(category_id: source.ikea_id).find_each do |row|
        duplicate_exists = ProductFilterValue.where(
          product_id: row.product_id,
          category_id: target.ikea_id,
          parameter: row.parameter,
          value_id: row.value_id
        ).where.not(id: row.id).exists?
    
        if duplicate_exists
          row.destroy!
        else
          row.update!(category_id: target.ikea_id)
        end
      end
    end

    def reassign_seo_meta!(source, target)
      return unless source.seo_meta.present?

      if target.seo_meta.blank?
        source.seo_meta.update!(seoable: target)
      end
    end

    def reassign_children_parent_ids!(source, target)
      impacted = Category.where(
        "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
        "%\"#{source.ikea_id}\"%",
        "%#{source.ikea_id}%"
      ).where.not(ikea_id: source.ikea_id)

      impacted.find_each do |child|
        parent_ids = Category.normalize_parent_ids(child.parent_ids)
        next if parent_ids.blank?

        replaced = parent_ids.map { |pid| pid.to_s == source.ikea_id.to_s ? target.ikea_id : pid }
        replaced = replaced.map(&:to_s).uniq

        child.update_columns(
          parent_ids: replaced.to_json,
          updated_at: Time.current
        )

        cache_delete_for_category_ids(child.ikea_id)
      end
    end
  end
end
