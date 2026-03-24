require 'json'
require 'fileutils'
require 'set'

module CategoryHierarchyImport
  class Importer
    DEFAULT_REPORT_DIR = Rails.root.join('tmp', 'category_hierarchy_import').freeze

    Result = Struct.new(:stats, :warnings, :errors, :report_path, :applied, keyword_init: true)

    def initialize(file_path:, dry_run: true, soft_delete_missing: false, purge_deleted_assets: false,
                   update_original_name: false, strict: true, normalize_visual_assets: true,
                   purge_misplaced_visuals: true, report_dir: DEFAULT_REPORT_DIR, logger: Rails.logger)
      @file_path = Pathname.new(file_path.to_s)
      @dry_run = dry_run
      @soft_delete_missing = soft_delete_missing
      @purge_deleted_assets = purge_deleted_assets
      @update_original_name = update_original_name
      @strict = strict
      @normalize_visual_assets = normalize_visual_assets
      @purge_misplaced_visuals = purge_misplaced_visuals
      @report_dir = Pathname.new(report_dir)
      @logger = logger
      @warnings = []
      @errors = []
      @stats = Hash.new(0)
      @report_payload = {
        started_at: Time.current.iso8601,
        file_path: @file_path.to_s,
        dry_run: @dry_run,
        soft_delete_missing: @soft_delete_missing,
        purge_deleted_assets: @purge_deleted_assets,
        update_original_name: @update_original_name,
        strict: @strict,
        normalize_visual_assets: @normalize_visual_assets,
        purge_misplaced_visuals: @purge_misplaced_visuals,
        validations: {},
        changes: {
          categories_to_update: [],
          categories_missing_in_db: [],
          orphan_candidates: [],
          orphan_soft_deleted: [],
          orphan_skipped_due_to_references: [],
          visual_asset_actions: []
        },
        warnings: @warnings,
        errors: @errors
      }
    end

    def call
      payload = load_payload!
      desired = build_desired_state!(payload)
      current_by_id = Category.unscoped.index_by { |c| c.ikea_id.to_s }

      validate_desired_state!(desired, current_by_id)

      return finish!(applied: false) if @errors.any? && @strict

      if @dry_run
        collect_change_preview!(desired, current_by_id)
        finish!(applied: false)
      else
        apply_changes!(desired, current_by_id)
        finish!(applied: true)
      end
    end

    private

    def load_payload!
      raise ArgumentError, "JSON file not found: #{@file_path}" unless @file_path.exist?

      JSON.parse(@file_path.read, symbolize_names: true)
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid JSON: #{e.message}"
    end

    def build_desired_state!(payload)
      categories = payload[:categories]
      raise ArgumentError, 'Expected root key `categories` with array value' unless categories.is_a?(Array)

      desired = {}
      seen_rows = Set.new

      walk_nodes(categories, [], desired, seen_rows)

      @report_payload[:validations][:desired_categories_count] = desired.size
      desired
    end

    def walk_nodes(nodes, ancestor_ids, desired, seen_rows)
      Array(nodes).each do |node|
        row = node[:row]
        seo_name = node[:seo_name].to_s.strip
        original_name = node[:original_name].to_s.strip
        source_occurrences = Array(node[:source_category_occurrences])

        if row.present?
          if seen_rows.include?(row)
            warn!("Duplicate row in import JSON: #{row}")
          else
            seen_rows << row
          end
        end

        donor_ikea_ids = source_occurrences.map { |occ| occ[:ikea_id].to_s.strip }.reject(&:blank?).uniq
        occurrence_ids = donor_ikea_ids.presence || Array(node[:ikea_ids_unique]).map(&:to_s).reject(&:blank?).uniq

        if occurrence_ids.empty?
          warn!("Node row=#{row || 'n/a'} seo_name=#{seo_name.inspect} has no ikea_id; it will be ignored")
          walk_nodes(node[:children], ancestor_ids, desired, seen_rows)
          next
        end

        if occurrence_ids.size > 1
          error!("Node row=#{row || 'n/a'} seo_name=#{seo_name.inspect} contains multiple ikea_id values: #{occurrence_ids.join(', ')}. Importer expects one physical DB category per node.")
          next
        end

        ikea_id = occurrence_ids.first
        attrs = {
          ikea_id: ikea_id,
          parent_ids: ancestor_ids.map(&:to_s),
          translated_name: seo_name.presence,
          original_name: original_name.presence,
          row: row,
          counted_in_xls_total: !!node[:counted_in_xls_total],
          source_occurrence_count: node[:source_occurrence_count].to_i,
          donor_ikea_ids: (donor_ikea_ids + [ikea_id]).map(&:to_s).uniq,
          raw_node: node
        }

        existing = desired[ikea_id]
        if existing && state_conflict?(existing, attrs)
          error!("Conflicting desired state for ikea_id=#{ikea_id}: #{existing.except(:raw_node).inspect} vs #{attrs.except(:raw_node).inspect}")
          next
        end

        desired[ikea_id] = attrs
        walk_nodes(node[:children], ancestor_ids + [ikea_id], desired, seen_rows)
      end
    end

    def state_conflict?(a, b)
      a[:parent_ids] != b[:parent_ids] ||
        a[:translated_name].to_s != b[:translated_name].to_s ||
        a[:original_name].to_s != b[:original_name].to_s
    end

    def validate_desired_state!(desired, current_by_id)
      missing_in_db = desired.keys.reject { |id| current_by_id.key?(id) }
      duplicate_active_names = Hash.new { |h, k| h[k] = [] }

      desired.each_value do |attrs|
        key = [attrs[:parent_ids], attrs[:translated_name].to_s.strip.downcase]
        duplicate_active_names[key] << attrs[:ikea_id]
      end

      duplicate_name_groups = duplicate_active_names.values.select { |ids| ids.size > 1 }

      @report_payload[:validations][:missing_in_db_count] = missing_in_db.size
      @report_payload[:validations][:duplicate_target_name_groups] = duplicate_name_groups.size
      @report_payload[:changes][:categories_missing_in_db] = missing_in_db.sort

      if missing_in_db.any?
        message = "Import file contains #{missing_in_db.size} ikea_id values absent in DB: #{missing_in_db.first(20).join(', ')}"
        @strict ? error!(message) : warn!(message)
      end

      duplicate_name_groups.each do |ids|
        warn!("Multiple active categories will share same parent_ids and translated_name after import: #{ids.join(', ')}")
      end
    end

    def collect_change_preview!(desired, current_by_id)
      desired.each_value do |attrs|
        category = current_by_id[attrs[:ikea_id]]
        next unless category

        changes = diff_for_category(category, attrs)
        next if changes.empty?

        @stats[:categories_to_update] += 1
        @report_payload[:changes][:categories_to_update] << preview_row(category, attrs, changes)
      end

      preview_visual_asset_actions!(desired, current_by_id)
      preview_orphans!(desired, current_by_id)
    end

    def apply_changes!(desired, current_by_id)
      ActiveRecord::Base.transaction do
        desired.keys.each_slice(200) do |slice|
          Category.lock.where(ikea_id: slice).pluck(:ikea_id)
        end

        desired.each_value do |attrs|
          category = current_by_id[attrs[:ikea_id]]
          next unless category

          changes = diff_for_category(category, attrs)
          next if changes.empty?

          assign_category_attributes!(category, attrs)
          category.save!

          @stats[:categories_updated] += 1
          @report_payload[:changes][:categories_to_update] << preview_row(category, attrs, changes)
          invalidate_category_cache!(category.ikea_id)
        end

        normalize_visual_assets!(desired, current_by_id) if @normalize_visual_assets
        process_orphans!(desired, current_by_id)
      end

      invalidate_global_caches!
    end

    def diff_for_category(category, attrs)
      changes = {}
      desired_parent_ids = attrs[:parent_ids].map(&:to_s)
      current_parent_ids = Category.normalize_parent_ids(category.parent_ids).map(&:to_s)

      changes[:translated_name] = [category.translated_name, attrs[:translated_name]] if attrs[:translated_name].present? && category.translated_name.to_s != attrs[:translated_name].to_s
      changes[:parent_ids] = [current_parent_ids, desired_parent_ids] if current_parent_ids != desired_parent_ids
      changes[:is_deleted] = [category.is_deleted, false] if category.is_deleted

      if @update_original_name && attrs[:original_name].present? && category.name.to_s != attrs[:original_name].to_s
        changes[:name] = [category.name, attrs[:original_name]]
      end

      changes
    end

    def assign_category_attributes!(category, attrs)
      category.parent_ids = attrs[:parent_ids]
      category.translated_name = attrs[:translated_name] if attrs[:translated_name].present?
      category.name = attrs[:original_name] if @update_original_name && attrs[:original_name].present?
      category.is_deleted = false
      category.is_important = attrs[:parent_ids].blank? if category.respond_to?(:is_important)
    end

    def preview_row(category, attrs, changes)
      {
        ikea_id: category.ikea_id,
        current_name: category.name,
        current_translated_name: category.translated_name,
        desired_translated_name: attrs[:translated_name],
        current_parent_ids: Category.normalize_parent_ids(category.parent_ids),
        desired_parent_ids: attrs[:parent_ids],
        row: attrs[:row],
        counted_in_xls_total: attrs[:counted_in_xls_total],
        changes: changes
      }
    end

    def preview_orphans!(desired, current_by_id)
      active_ids = current_by_id.values.select { |c| !c.is_deleted }.map { |c| c.ikea_id.to_s }
      orphan_ids = active_ids - desired.keys
      @report_payload[:validations][:active_categories_not_in_import] = orphan_ids.size

      orphan_ids.sort.each do |ikea_id|
        category = current_by_id[ikea_id]
        refs = reference_summary_for(category)
        row = { ikea_id: ikea_id, translated_name: category.translated_name, name: category.name, references: refs }
        @report_payload[:changes][:orphan_candidates] << row
        @stats[:orphan_candidates] += 1
      end
    end

    def process_orphans!(desired, current_by_id)
      preview_orphans!(desired, current_by_id)
      return unless @soft_delete_missing

      orphan_ids = @report_payload[:changes][:orphan_candidates].map { |row| row[:ikea_id] }

      orphan_ids.each do |ikea_id|
        category = current_by_id[ikea_id]
        next unless category

        refs = reference_summary_for(category)
        if refs.values.any? { |count| count.positive? }
          @report_payload[:changes][:orphan_skipped_due_to_references] << {
            ikea_id: ikea_id,
            translated_name: category.translated_name,
            references: refs
          }
          @stats[:orphans_skipped] += 1
          next
        end

        category.update!(is_deleted: true)
        purge_category_assets!(category) if @purge_deleted_assets
        clear_remote_category_images!(category)
        invalidate_category_cache!(category.ikea_id)

        @report_payload[:changes][:orphan_soft_deleted] << { ikea_id: ikea_id, translated_name: category.translated_name }
        @stats[:orphans_soft_deleted] += 1
      end
    end

    def preview_visual_asset_actions!(desired, current_by_id)
      desired.each_value do |attrs|
        target = current_by_id[attrs[:ikea_id]]
        next unless target

        actions = planned_visual_asset_actions_for(target, attrs, current_by_id)
        next if actions.empty?

        @stats[:visual_asset_actions_planned] += actions.size
        @report_payload[:changes][:visual_asset_actions].concat(actions)
      end
    end

    def normalize_visual_assets!(desired, current_by_id)
      desired.each_value do |attrs|
        target = current_by_id[attrs[:ikea_id]]
        next unless target

        actions = planned_visual_asset_actions_for(target, attrs, current_by_id)
        next if actions.empty?

        actions.each { |action| apply_visual_asset_action!(action, current_by_id) }
      end
    end

    def planned_visual_asset_actions_for(target, attrs, current_by_id)
      depth = attrs[:parent_ids].size
      donor_ids = Array(attrs[:donor_ikea_ids]).map(&:to_s).uniq
      actions = []

      case depth
      when 0
        actions.concat(planned_attach_action_for(target, donor_ids, current_by_id, :pictogram, depth))
        actions.concat(planned_purge_action_for(target, :icon, depth, 'root category must not keep icon')) if @purge_misplaced_visuals
      when 1
        actions.concat(planned_attach_action_for(target, donor_ids, current_by_id, :icon, depth))
        actions.concat(planned_purge_action_for(target, :pictogram, depth, 'second-level category must not keep pictogram')) if @purge_misplaced_visuals
      else
        if @purge_misplaced_visuals
          actions.concat(planned_purge_action_for(target, :icon, depth, 'deep category must not keep icon'))
          actions.concat(planned_purge_action_for(target, :pictogram, depth, 'deep category must not keep pictogram'))
        end
      end

      actions
    end

    def planned_attach_action_for(target, donor_ids, current_by_id, attachment_name, depth)
      target_attachment = target.public_send(attachment_name)
      return [] if target_attachment.respond_to?(:attached?) && target_attachment.attached?

      donors = donor_ids.filter_map { |id| current_by_id[id] }
      donors_with_attachment = donors.select do |candidate|
        attachment = candidate.public_send(attachment_name)
        attachment.respond_to?(:attached?) && attachment.attached?
      end
      return [] if donors_with_attachment.empty?

      chosen = choose_best_visual_donor(donors_with_attachment, target)
      if donors_with_attachment.size > 1
        warn!("Multiple #{attachment_name} donors for target ikea_id=#{target.ikea_id}: #{donors_with_attachment.map(&:ikea_id).join(', ')}. Selected #{chosen.ikea_id}.")
      end

      [{
        action: 'attach',
        attachment: attachment_name.to_s,
        target_ikea_id: target.ikea_id.to_s,
        target_translated_name: target.translated_name,
        from_ikea_id: chosen.ikea_id.to_s,
        depth: depth,
        reason: "#{visual_role_label(depth)} category should have #{attachment_name}"
      }]
    end

    def planned_purge_action_for(target, attachment_name, depth, reason)
      attachment = target.public_send(attachment_name)
      return [] unless attachment.respond_to?(:attached?) && attachment.attached?

      [{
        action: 'purge',
        attachment: attachment_name.to_s,
        target_ikea_id: target.ikea_id.to_s,
        target_translated_name: target.translated_name,
        from_ikea_id: nil,
        depth: depth,
        reason: reason
      }]
    end

    def choose_best_visual_donor(candidates, target)
      candidates.find { |candidate| candidate.ikea_id.to_s == target.ikea_id.to_s } ||
        candidates.find { |candidate| !candidate.is_deleted? } ||
        candidates.first
    end

    def apply_visual_asset_action!(action, current_by_id)
      target = current_by_id[action[:target_ikea_id].to_s]
      return unless target

      attachment_name = action[:attachment].to_sym

      case action[:action]
      when 'attach'
        donor = current_by_id[action[:from_ikea_id].to_s]
        return unless donor

        donor_attachment = donor.public_send(attachment_name)
        target_attachment = target.public_send(attachment_name)
        return unless donor_attachment.respond_to?(:attached?) && donor_attachment.attached?
        return if target_attachment.respond_to?(:attached?) && target_attachment.attached?

        target_attachment.attach(donor_attachment.blob)
        @stats[:visual_assets_attached] += 1
      when 'purge'
        target_attachment = target.public_send(attachment_name)
        return unless target_attachment.respond_to?(:attached?) && target_attachment.attached?

        target_attachment.purge
        @stats[:visual_assets_purged] += 1
      end

      @report_payload[:changes][:visual_asset_actions] << action
    rescue => e
      warn!("Failed visual asset action #{action.inspect}: #{e.class} #{e.message}")
    end

    def visual_role_label(depth)
      case depth
      when 0 then 'root'
      when 1 then 'second-level'
      else 'deep'
      end
    end

    def reference_summary_for(category)
      ikea_id = category.ikea_id.to_s
      {
        products_legacy: Product.where(category_id: ikea_id).count,
        products_join: CategoryProduct.where(category_id: ikea_id).count,
        filter_values: ProductFilterValue.where(category_id: ikea_id).count,
        home_banners: HomeBanner.where(category_id: ikea_id).count,
        content_article_categories: ContentArticleCategory.where(category_id: ikea_id).count,
        promo_code_categories: PromoCodeCategory.where(category_id: ikea_id).count,
        active_children: Category.active.where("parent_ids::text LIKE ?", "%\"#{ikea_id}\"%").where.not(ikea_id: ikea_id).count,
        article_body_blocks: content_articles_with_category_ref(ikea_id).size
      }
    end

    def content_articles_with_category_ref(ikea_id)
      candidates = ContentArticle.where("body_blocks::text LIKE ?", "%#{ikea_id}%")
      candidates.select do |article|
        body_blocks_reference_category?(article.body_blocks, ikea_id)
      end
    end

    def body_blocks_reference_category?(blocks, ikea_id)
      Array.wrap(blocks).any? do |block|
        next false unless block.is_a?(Hash)

        block['button_category_id'].to_s == ikea_id ||
          block['slider_category_id'].to_s == ikea_id ||
          Array.wrap(block['grid_category_ids']).map(&:to_s).include?(ikea_id)
      end
    end

    def purge_category_assets!(category)
      %i[icon pictogram background_image].each do |attachment_name|
        attachment = category.public_send(attachment_name)
        next unless attachment.respond_to?(:attached?) && attachment.attached?

        attachment.purge
        @stats[:attachments_purged] += 1
      end
    rescue => e
      warn!("Failed to purge attachments for category #{category.ikea_id}: #{e.class} #{e.message}")
    end

    def clear_remote_category_images!(category)
      updates = {}
      updates[:remote_image_url] = nil if category.respond_to?(:remote_image_url) && category.remote_image_url.present?
      updates[:local_image_path] = nil if category.respond_to?(:local_image_path) && category.local_image_path.present?
      return if updates.empty?

      category.update_columns(updates.merge(updated_at: Time.current))
      @stats[:remote_images_cleared] += 1
    rescue => e
      warn!("Failed to clear remote images for category #{category.ikea_id}: #{e.class} #{e.message}")
    end

    def invalidate_category_cache!(ikea_id)
      Rails.cache.delete("category_#{ikea_id}_children_count")
    end

    def invalidate_global_caches!
      %w[
        categories_tree_json
        categories_map_json
        categories_product_counts
        categories_children_counts
        categories_max_updated_at
      ].each { |key| Rails.cache.delete(key) }

      Rails.cache.delete_matched('category_*_children_count') if Rails.cache.respond_to?(:delete_matched)
    rescue => e
      warn!("Failed to clear category caches: #{e.class} #{e.message}")
    end

    def finish!(applied:)
      FileUtils.mkdir_p(@report_dir)
      timestamp = Time.current.strftime('%Y%m%d-%H%M%S')
      report_path = @report_dir.join("category_hierarchy_import_#{timestamp}.json")
      @report_payload[:finished_at] = Time.current.iso8601
      @report_payload[:stats] = @stats
      @report_payload[:applied] = applied
      @report_payload[:warnings] = @warnings
      @report_payload[:errors] = @errors
      report_path.write(JSON.pretty_generate(@report_payload))

      Result.new(
        stats: @stats,
        warnings: @warnings,
        errors: @errors,
        report_path: report_path.to_s,
        applied: applied
      )
    end

    def warn!(message)
      @warnings << message
      @logger.warn("CategoryHierarchyImport: #{message}")
    end

    def error!(message)
      @errors << message
      @logger.error("CategoryHierarchyImport: #{message}")
    end
  end
end
