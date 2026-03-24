class ImportCategoryHierarchyJob < ApplicationJob
  queue_as :parser

  def perform(file_path:, dry_run: true, soft_delete_missing: false, purge_deleted_assets: false,
              update_original_name: false, strict: true, normalize_visual_assets: true,
              purge_misplaced_visuals: true)
    importer = CategoryHierarchyImport::Importer.new(
      file_path: file_path,
      dry_run: dry_run,
      soft_delete_missing: soft_delete_missing,
      purge_deleted_assets: purge_deleted_assets,
      update_original_name: update_original_name,
      strict: strict,
      normalize_visual_assets: normalize_visual_assets,
      purge_misplaced_visuals: purge_misplaced_visuals
    )

    result = importer.call

    Rails.logger.info(
      "ImportCategoryHierarchyJob finished: applied=#{result.applied} " \
      "errors=#{result.errors.size} warnings=#{result.warnings.size} report=#{result.report_path}"
    )

    raise StandardError, result.errors.join("\n") if strict && result.errors.any?

    result.report_path
  end
end
