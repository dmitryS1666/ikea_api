# frozen_string_literal: true

namespace :categories do
  ICON_NAME_RENAMES = {
    "Декор" => "Декоративные фигурки, статуэтки и украшения",
    "Зеркала для ванной" => "Зеркала в ванную комнату",
    "Посуда для сервировки" => "Столовая посуда",
    "Настенные украшения" => "Фотографии и декоротивные рисунки",
    "Диваны нераскладные" => "Раскладные диваны",
    "Рабочие столы и кресла" => "Столы и стулья",
    "Портативная бытовая техника" => "Бытовая техника",
    "Посуда, формы для выпечки и запекания" => "Кастрюли",
    "Контейнеры для хранения продуктов" => "Контейнеры для еды и крышки",
    "Настольные лампы" => "Настольные светильники",
    "Системы умного освещения" => "Умное освещение",
    "Раскладные столы" => "Раскладные и раздвижные столы",
    "Офисные столы" => "Столы",
    "Полы, настилы для балконов и террас" => "Ковры для балкона и террасы",
    "Плечики и вешалки для одежды" => "Вешалки настенные и крючки для одежды",
    "Тюль" => "Полупрозрачные шторы"
  }.freeze

  def bool_env(key, default: false)
    return default unless ENV.key?(key)

    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  desc 'Preview/apply translated_name rollback to icon file naming. Use CONFIRM=YES to apply.'
  task :align_translated_names_to_icon_names => :environment do
    dry_run = ENV['CONFIRM'].to_s != 'YES'
    log_dir = Rails.root.join('log')
    FileUtils.mkdir_p(log_dir)
    log_path = log_dir.join('align_translated_names_to_icon_names.log')

    stats = {
      planned: 0,
      updated: 0,
      unchanged: 0,
      not_found: 0,
      ambiguous: 0,
      conflicts: 0,
      errors: 0
    }

    started_at = Time.current

    File.open(log_path, 'a:utf-8') do |log|
      log.puts "\n" + ('=' * 100)
      log.puts "[#{started_at}] START categories:align_translated_names_to_icon_names dry_run=#{dry_run}"
      log.puts ('=' * 100)

      ICON_NAME_RENAMES.each do |current_name, target_name|
        matches = Category.where(translated_name: current_name).to_a

        if matches.empty?
          stats[:not_found] += 1
          message = "NOT_FOUND current_translated_name=#{current_name.inspect} target=#{target_name.inspect}"
          puts message
          log.puts "[#{Time.current}] #{message}"
          next
        end

        if matches.size > 1 && !bool_env('ALLOW_MULTI', default: false)
          stats[:ambiguous] += 1
          message = "AMBIGUOUS current_translated_name=#{current_name.inspect} count=#{matches.size} ikea_ids=#{matches.map(&:ikea_id).join(',')}"
          puts message
          log.puts "[#{Time.current}] #{message}"
          next
        end

        matches.each do |category|
          normalized_target = target_name.to_s.squish
          current_parent_ids = Category.normalize_parent_ids(category.parent_ids).map(&:to_s)

          sibling_conflict = Category.where.not(id: category.id)
            .where(translated_name: normalized_target)
            .select do |other|
              Category.normalize_parent_ids(other.parent_ids).map(&:to_s) == current_parent_ids
            end

          if sibling_conflict.any?
            stats[:conflicts] += 1
            message = "CONFLICT ikea_id=#{category.ikea_id} current=#{current_name.inspect} target=#{normalized_target.inspect} conflicting_ikea_ids=#{sibling_conflict.map(&:ikea_id).join(',')}"
            puts message
            log.puts "[#{Time.current}] #{message}"
            next
          end

          if category.translated_name.to_s == normalized_target
            stats[:unchanged] += 1
            message = "UNCHANGED ikea_id=#{category.ikea_id} translated_name=#{normalized_target.inspect}"
            puts message
            log.puts "[#{Time.current}] #{message}"
            next
          end

          stats[:planned] += 1
          message = "PLAN ikea_id=#{category.ikea_id} #{category.translated_name.inspect} -> #{normalized_target.inspect} parent_ids=#{current_parent_ids.inspect}"
          puts message
          log.puts "[#{Time.current}] #{message}"

          next if dry_run

          begin
            category.update!(translated_name: normalized_target)
            stats[:updated] += 1
            log.puts "[#{Time.current}] UPDATED ikea_id=#{category.ikea_id} translated_name=#{normalized_target.inspect}"
          rescue => e
            stats[:errors] += 1
            error_message = "ERROR ikea_id=#{category.ikea_id} #{e.class}: #{e.message}"
            puts error_message
            log.puts "[#{Time.current}] #{error_message}"
          end
        end
      end

      %w[
        categories_tree_json
        categories_map_json
        categories_product_counts
        categories_children_counts
        categories_max_updated_at
      ].each { |key| Rails.cache.delete(key) } unless dry_run

      Rails.cache.delete_matched('category_*_children_count') if !dry_run && Rails.cache.respond_to?(:delete_matched)

      summary = <<~TEXT

        #{'=' * 100}
        [#{Time.current}] FINISH categories:align_translated_names_to_icon_names
        dry_run: #{dry_run}
        planned: #{stats[:planned]}
        updated: #{stats[:updated]}
        unchanged: #{stats[:unchanged]}
        not_found: #{stats[:not_found]}
        ambiguous: #{stats[:ambiguous]}
        conflicts: #{stats[:conflicts]}
        errors: #{stats[:errors]}
        log: #{log_path}
        #{'=' * 100}
      TEXT

      log.puts summary
      puts summary
    end
  end

  desc 'List .png files with double spaces in file names. Usage: rake categories:report_icon_png_double_spaces[/path/to/folder]'
  task :report_icon_png_double_spaces, [:folder_path] => :environment do |_t, args|
    folder_path = (args[:folder_path].presence || Rails.root.join('icons')).to_s
    abort "Folder not found: #{folder_path}" unless Dir.exist?(folder_path)

    files = Dir.glob(File.join(folder_path, '**', '*.png')).select { |f| File.file?(f) }
    offenders = files.map { |f| File.basename(f) }.select { |name| name.match?(/  +/) }.sort

    puts "Folder: #{folder_path}"
    puts "PNG files with double spaces: #{offenders.size}"

    if offenders.empty?
      puts 'No .png files with double spaces found.'
    else
      offenders.each { |name| puts name }
    end
  end
end
