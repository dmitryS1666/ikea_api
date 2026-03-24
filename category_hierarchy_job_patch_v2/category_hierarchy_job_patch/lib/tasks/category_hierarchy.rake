namespace :category_hierarchy do
  desc 'Preview category hierarchy import from JSON file. Usage: rake category_hierarchy:dry_run[/path/to/file.json]'
  task :dry_run, [:file_path] => :environment do |_t, args|
    file_path = args[:file_path].presence || ENV['FILE']
    abort 'Provide file path via argument or FILE=/path/to/file.json' if file_path.blank?

    result = CategoryHierarchyImport::Importer.new(
      file_path: file_path,
      dry_run: true,
      soft_delete_missing: ActiveModel::Type::Boolean.new.cast(ENV['SOFT_DELETE_MISSING']),
      purge_deleted_assets: ActiveModel::Type::Boolean.new.cast(ENV['PURGE_DELETED_ASSETS']),
      update_original_name: ActiveModel::Type::Boolean.new.cast(ENV['UPDATE_ORIGINAL_NAME']),
      strict: !ActiveModel::Type::Boolean.new.cast(ENV['NON_STRICT']),
      normalize_visual_assets: !ENV.key?('NORMALIZE_VISUAL_ASSETS') || ActiveModel::Type::Boolean.new.cast(ENV['NORMALIZE_VISUAL_ASSETS']),
      purge_misplaced_visuals: !ENV.key?('PURGE_MISPLACED_VISUALS') || ActiveModel::Type::Boolean.new.cast(ENV['PURGE_MISPLACED_VISUALS'])
    ).call

    puts "Dry run completed."
    puts "  Report: #{result.report_path}"
    puts "  Warnings: #{result.warnings.size}"
    puts "  Errors: #{result.errors.size}"
    puts "  Stats: #{result.stats.inspect}"

    abort('Dry run finished with errors') if result.errors.any? && !ActiveModel::Type::Boolean.new.cast(ENV['NON_STRICT'])
  end

  desc 'Apply category hierarchy import from JSON file. Usage: rake category_hierarchy:apply[/path/to/file.json]'
  task :apply, [:file_path] => :environment do |_t, args|
    file_path = args[:file_path].presence || ENV['FILE']
    abort 'Provide file path via argument or FILE=/path/to/file.json' if file_path.blank?

    confirm = ENV['CONFIRM'].to_s
    abort "Set CONFIRM=YES to apply changes" unless confirm == 'YES'

    result = CategoryHierarchyImport::Importer.new(
      file_path: file_path,
      dry_run: false,
      soft_delete_missing: ActiveModel::Type::Boolean.new.cast(ENV['SOFT_DELETE_MISSING']),
      purge_deleted_assets: ActiveModel::Type::Boolean.new.cast(ENV['PURGE_DELETED_ASSETS']),
      update_original_name: ActiveModel::Type::Boolean.new.cast(ENV['UPDATE_ORIGINAL_NAME']),
      strict: !ActiveModel::Type::Boolean.new.cast(ENV['NON_STRICT']),
      normalize_visual_assets: !ENV.key?('NORMALIZE_VISUAL_ASSETS') || ActiveModel::Type::Boolean.new.cast(ENV['NORMALIZE_VISUAL_ASSETS']),
      purge_misplaced_visuals: !ENV.key?('PURGE_MISPLACED_VISUALS') || ActiveModel::Type::Boolean.new.cast(ENV['PURGE_MISPLACED_VISUALS'])
    ).call

    puts "Apply completed."
    puts "  Report: #{result.report_path}"
    puts "  Applied: #{result.applied}"
    puts "  Warnings: #{result.warnings.size}"
    puts "  Errors: #{result.errors.size}"
    puts "  Stats: #{result.stats.inspect}"

    abort('Apply finished with errors') if result.errors.any? && !ActiveModel::Type::Boolean.new.cast(ENV['NON_STRICT'])
  end
end
