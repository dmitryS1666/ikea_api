module CategoryCleanup
  class DryRun < Base
    def call
      report = {
        delete: [],
        merge: [],
        failed_rules: [],
        summary: {}
      }

      CategoryCleanupRule.order(:source_row_no).find_each do |rule|
        unless rule.resolution_status == 'resolved'
          report[:failed_rules] << failed_rule_payload(rule)
          next
        end

        source = Category.find_by(ikea_id: rule.resolved_source_ikea_id)
        target = Category.find_by(ikea_id: rule.resolved_target_ikea_id) if rule.action == 'merge'

        if rule.action == 'delete'
          report[:delete] << {
            source_row_no: rule.source_row_no,
            source_ikea_id: source&.ikea_id,
            source_name: source&.name,
            old_products_count: count_legacy_products(source),
            join_products_count: count_join_products(source),
            filter_values_count: count_filter_values(source),
            children_count: source&.children_count.to_i
          }
        elsif rule.action == 'merge'
          report[:merge] << {
            source_row_no: rule.source_row_no,
            source_ikea_id: source&.ikea_id,
            source_name: source&.name,
            target_ikea_id: target&.ikea_id,
            target_name: target&.name,
            old_products_count: count_legacy_products(source),
            join_products_count: count_join_products(source),
            filter_values_count: count_filter_values(source),
            children_count: source&.children_count.to_i
          }
        end
      end

      report[:summary] = {
        total_rules: CategoryCleanupRule.count,
        resolved_rules: CategoryCleanupRule.where(resolution_status: 'resolved').count,
        failed_rules: CategoryCleanupRule.where.not(resolution_status: 'resolved').count,
        delete_rules: report[:delete].size,
        merge_rules: report[:merge].size
      }

      report
    end

    private

    def failed_rule_payload(rule)
      {
        source_row_no: rule.source_row_no,
        raw_status: rule.raw_status,
        action: rule.action,
        resolution_status: rule.resolution_status,
        source_ikea_id: rule.source_ikea_id,
        target_ikea_id: rule.target_ikea_id,
        target_row_no: rule.target_row_no,
        notes: rule.notes
      }
    end

    def count_legacy_products(category)
      return 0 unless category
      Product.where(category_id: category.ikea_id).count
    end

    def count_join_products(category)
      return 0 unless category
      CategoryProduct.where(category_id: category.ikea_id).count
    end

    def count_filter_values(category)
      return 0 unless category
      ProductFilterValue.where(category_id: category.ikea_id).count
    end
  end
end
