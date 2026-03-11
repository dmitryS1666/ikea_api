module CategoryCleanup
  class BuildRowMappings < Base
    def call
      full_rows = FullCatalogReader.new.call.index_by(&:row_no)
      decisions = CategoryCleanupRule.all.index_by(&:source_row_no)

      referenced_row_numbers = (
        decisions.keys +
        decisions.values.map(&:target_row_no)
      ).compact.uniq.sort

      CategoryCatalogRowMapping.transaction do
        CategoryCatalogRowMapping.delete_all

        referenced_row_numbers.each do |row_no|
          full_row = full_rows[row_no]
          decision = decisions[row_no]

          resolved = resolve_row(row_no: row_no, full_row: full_row, decision: decision)

          CategoryCatalogRowMapping.create!(
            row_no: row_no,
            ikea_id: resolved[:ikea_id],
            matched_by: resolved[:matched_by],
            confidence: resolved[:confidence],
            raw_name: full_row&.raw_name,
            seo_name: full_row&.seo_name,
            path: full_row&.path,
            depth: full_row&.depth,
            meta: resolved[:meta] || {}
          )
        end
      end
    end

    private

    def resolve_row(row_no:, full_row:, decision:)
      if decision&.source_ikea_id.present?
        category = Category.find_by(ikea_id: decision.source_ikea_id.to_s)
        if category
          return resolved_hash(category, 'source_ikea_id', 1.0)
        end
      end

      if decision&.source_url.present?
        candidates = Category.where(url: decision.source_url)
        if candidates.one?
          return resolved_hash(candidates.first, 'source_url', 0.95)
        end
        if candidates.many?
          return {
            ikea_id: nil,
            matched_by: 'source_url_ambiguous',
            confidence: 0.0,
            meta: { candidate_ids: candidates.pluck(:ikea_id) }
          }
        end
      end

      return unresolved_hash('full_row_missing') if full_row.nil?

      candidates = candidates_by_names(full_row)

      if candidates.one?
        return resolved_hash(candidates.first, 'full_catalog_name', 0.75)
      end

      if candidates.many?
        narrowed = narrow_by_path(candidates, full_row)
        if narrowed.one?
          return resolved_hash(narrowed.first, 'full_catalog_name_and_path', 0.85)
        end

        return {
          ikea_id: nil,
          matched_by: 'name_ambiguous',
          confidence: 0.0,
          meta: {
            candidate_ids: narrowed.presence&.map(&:ikea_id) || candidates.map(&:ikea_id)
          }
        }
      end

      unresolved_hash('not_found')
    end

    def candidates_by_names(full_row)
      names = [full_row.raw_name, full_row.seo_name].compact.map { |v| clean_tree_name(v) }.uniq
      return Category.none if names.blank?

      categories = Category.select(:ikea_id, :name, :translated_name, :parent_ids)

      categories.select do |category|
        category_names = [category.name, category.translated_name].compact.map { |v| clean_tree_name(v) }
        (category_names & names).any?
      end
    end

    def narrow_by_path(candidates, full_row)
      path_tokens = full_row.path.to_s.split('>').map { |v| clean_tree_name(v) }.reject(&:blank?)
      return candidates if path_tokens.blank?

      candidates.select do |category|
        category_tokens = [category.name, category.translated_name].compact.map { |v| clean_tree_name(v) }
        (category_tokens & path_tokens).any?
      end
    end

    def resolved_hash(category, matched_by, confidence)
      {
        ikea_id: category.ikea_id,
        matched_by: matched_by,
        confidence: confidence,
        meta: {}
      }
    end

    def unresolved_hash(reason)
      {
        ikea_id: nil,
        matched_by: reason,
        confidence: 0.0,
        meta: {}
      }
    end
  end
end
