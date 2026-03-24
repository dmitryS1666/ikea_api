# frozen_string_literal: true

namespace :category_hierarchy do
  def boolean_env(key, default: false)
    return default unless ENV.key?(key)

    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def build_importer(file_path:, dry_run:)
    CategoryHierarchyImport::Importer.new(
      file_path: file_path,
      dry_run: dry_run,
      soft_delete_missing: boolean_env('SOFT_DELETE_MISSING', default: false),
      purge_deleted_assets: boolean_env('PURGE_DELETED_ASSETS', default: false),
      update_original_name: boolean_env('UPDATE_ORIGINAL_NAME', default: false),
      strict: !boolean_env('NON_STRICT', default: false),
      normalize_visual_assets: boolean_env('NORMALIZE_VISUAL_ASSETS', default: true),
      purge_misplaced_visuals: boolean_env('PURGE_MISPLACED_VISUALS', default: true),
      conflict_resolutions: CategoryHierarchyImport::ConflictResolutions::CATEGORY_CONFLICT_RESOLUTIONS
    )
  end

  desc 'Preview category hierarchy import from JSON file. Usage: rake category_hierarchy:dry_run[/path/to/file.json]'
  task :dry_run, [:file_path] => :environment do |_t, args|
    file_path = args[:file_path].presence || ENV['FILE']
    abort 'Provide file path via argument or FILE=/path/to/file.json' if file_path.blank?

    result = build_importer(file_path: file_path, dry_run: true).call

    puts 'Dry run completed.'
    puts "  Report: #{result.report_path}"
    puts "  Applied: #{result.applied}"
    puts "  Warnings: #{result.warnings.size}"
    puts "  Errors: #{result.errors.size}"
    puts "  Stats: #{result.stats.inspect}"

    abort('Dry run finished with errors') if result.errors.any? && !boolean_env('NON_STRICT', default: false)
  end

  desc 'Apply category hierarchy import from JSON file. Usage: rake category_hierarchy:apply[/path/to/file.json]'
  task :apply, [:file_path] => :environment do |_t, args|
    file_path = args[:file_path].presence || ENV['FILE']
    abort 'Provide file path via argument or FILE=/path/to/file.json' if file_path.blank?

    abort 'Set CONFIRM=YES to apply changes' unless ENV['CONFIRM'].to_s == 'YES'

    result = build_importer(file_path: file_path, dry_run: false).call

    puts 'Apply completed.'
    puts "  Report: #{result.report_path}"
    puts "  Applied: #{result.applied}"
    puts "  Warnings: #{result.warnings.size}"
    puts "  Errors: #{result.errors.size}"
    puts "  Stats: #{result.stats.inspect}"

    abort('Apply finished with errors') if result.errors.any? && !boolean_env('NON_STRICT', default: false)
  end
end
