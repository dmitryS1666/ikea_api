module CategoryCleanup
  class ResolveRules < Base
    def call
      rules = CategoryCleanupRule
          .where.not(resolution_status: %w[ambiguous skipped applied])
          .order(:source_row_no)
      row_mappings = CategoryCatalogRowMapping.all.index_by(&:row_no)

      rules.find_each do |rule|
        resolve_rule(rule, row_mappings)
      end
    end

    private

    def resolve_rule(rule, row_mappings)
      source_resolution = resolve_source(rule, row_mappings)
      target_resolution = resolve_target(rule, row_mappings)

      notes = []
      status = 'resolved'

      if source_resolution[:ikea_id].blank?
        if rule.action == 'delete' && rule.source_ikea_id.blank? && rule.source_url.blank?
          status = 'skipped'
          notes << "No source category in DB; likely service/full-catalog row"
        else
          status = 'failed'
          notes << "Source category not resolved"
        end
      end

      if rule.action == 'merge' && target_resolution[:ikea_id].blank?
        status = 'failed'
        notes << "Target category not resolved"
      end

      if source_resolution[:ikea_id].present? &&
         target_resolution[:ikea_id].present? &&
         source_resolution[:ikea_id].to_s == target_resolution[:ikea_id].to_s
        status = 'skipped'
        notes << "Source and target are identical; nothing to merge"
      end

      if rule.action == 'review'
        status = 'ambiguous'
        notes << "Manual review required"
      end

      rule.update!(
        resolved_source_ikea_id: source_resolution[:ikea_id],
        resolved_target_ikea_id: target_resolution[:ikea_id],
        source_matched_by: source_resolution[:matched_by],
        target_matched_by: target_resolution[:matched_by],
        resolution_status: status,
        notes: [rule.notes, notes.join('; ')].compact.reject(&:blank?).join(' | ')
      )
    end

    def resolve_source(rule, row_mappings)
      if rule.source_ikea_id.present?
        category = Category.find_by(ikea_id: rule.source_ikea_id)
        return { ikea_id: category.ikea_id, matched_by: 'rule_source_ikea_id' } if category
      end

      if rule.source_url.present?
        url_ikea_id = ikea_id_from_url(rule.source_url)
        if url_ikea_id.present?
          category = Category.find_by(ikea_id: url_ikea_id)
          return { ikea_id: category.ikea_id, matched_by: 'rule_source_url_ikea_id' } if category
        end
      end

      if rule.source_url.present?
        candidates = Category.where(url: rule.source_url)
        if candidates.one?
          return {
            ikea_id: nil,
            matched_by: 'full_catalog_name_requires_review',
            confidence: 0.0,
            meta: { candidate_ids: [candidates.first.ikea_id] }
          }
        end
      end

      mapping = row_mappings[rule.source_row_no]
      return { ikea_id: mapping.ikea_id, matched_by: "row_mapping:#{mapping.matched_by}" } if mapping&.ikea_id.present?

      { ikea_id: nil, matched_by: nil }
    end

    def resolve_target(rule, row_mappings)
      return { ikea_id: nil, matched_by: nil } unless rule.action == 'merge'

      if rule.target_ikea_id.present?
        category = Category.find_by(ikea_id: rule.target_ikea_id)
        return { ikea_id: category.ikea_id, matched_by: 'rule_target_ikea_id' } if category
      end

      if rule.target_row_no.present?
        mapping = row_mappings[rule.target_row_no]
        return { ikea_id: mapping.ikea_id, matched_by: "row_mapping:#{mapping.matched_by}" } if mapping&.ikea_id.present?
      end

      { ikea_id: nil, matched_by: nil }
    end
  end
end
