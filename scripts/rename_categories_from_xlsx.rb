# frozen_string_literal: true

# Usage:
#   bundle exec rails runner script/rename_categories_from_xlsx.rb /path/to/catalog.xlsx
#
# Dry-run by default (prints actions only).
# Apply changes:
#   APPLY=1 bundle exec rails runner script/rename_categories_from_xlsx.rb /path/to/catalog.xlsx
#
# Optional:
#   SHEET="Только категории, которые меняе" APPLY=1 bundle exec rails runner script/rename_categories_from_xlsx.rb file.xlsx

require "roo"

# ====== CONFIG ======
DEFAULT_SHEET = ENV.fetch("SHEET", "Только категории, которые меняе")
APPLY = ENV["APPLY"].to_s == "1"

# Model name can differ. Change if needed:
CATEGORY_MODEL_NAME = ENV.fetch("MODEL", "Category")

# Columns used to represent tree levels in Excel:
TREE_COLS = [0, 1, 2, 3, 4].freeze
NEW_NAME_COL = 5

# ====== HELPERS ======
def abort_with(msg)
  warn "\nERROR: #{msg}\n\n"
  exit 1
end

def clean_tree_cell(value)
  return nil if value.nil?
  s = value.to_s
  s = s.gsub(/^[\s│└─]+/, "")     # remove tree glyphs at start
  s = s.gsub(/[📂📁📄]/, "")      # remove emojis if present
  s = s.strip
  s.empty? ? nil : s
end

def normalize_space(s)
  s.to_s.gsub(/\s+/, " ").strip
end

def safe_update!(record, attrs)
  attrs.each { |k, v| attrs[k] = normalize_space(v) if v.is_a?(String) }
  record.update!(attrs)
end

# ====== BOOTSTRAP ======
file_path = ARGV[0]
abort_with("XLSX path is required") if file_path.nil? || file_path.strip.empty?
abort_with("File not found: #{file_path}") unless File.exist?(file_path)

Category = Object.const_get(CATEGORY_MODEL_NAME)
abort_with("Model #{CATEGORY_MODEL_NAME} not found") unless Category.respond_to?(:column_names)

colnames = Category.column_names
has_seo_name = colnames.include?("seo_name")
has_h1 = colnames.include?("h1")

puts "== Rename Categories from XLSX =="
puts "File:  #{file_path}"
puts "Sheet: #{DEFAULT_SHEET}"
puts "Mode:  #{APPLY ? "APPLY (writes to DB)" : "DRY-RUN (no DB writes)"}"
puts "Model: #{CATEGORY_MODEL_NAME}"
puts "Columns: name#{has_seo_name ? ", seo_name" : ""}#{has_h1 ? ", h1" : ""}"
puts "================================="

xlsx = Roo::Excelx.new(file_path)
sheet = xlsx.sheet(DEFAULT_SHEET)

headers = sheet.row(1).map(&:to_s)
# header_index = headers.each_with_index.to_h

# missing = TREE_COLS.reject { |c| header_index.key?(c) }
# abort_with("Missing tree columns in sheet header: #{missing.join(", ")}") unless missing.empty?
# abort_with("Missing column '#{NEW_NAME_COL}' in sheet header") unless header_index.key?(NEW_NAME_COL)

# stack[level] holds current name at that level
stack = Array.new(TREE_COLS.size)

# When we rename something, later traversal may need new name.
# Keep a map: "parent_id|old_name" => new_name
renamed_cache = {}

# stats
planned = 0
applied = 0
skipped_same = 0
not_found = []
ambiguous = []

# ====== CORE ======
(2..sheet.last_row).each do |r|
  row = sheet.row(r)

  level_changed = nil
  level_name = nil

  TREE_COLS.each_with_index do |col_idx, idx|
    cell = row[col_idx]
    next if cell.nil? || cell.to_s.strip.empty?

    cleaned = clean_tree_cell(cell)
    next if cleaned.nil?

    level_changed = idx
    level_name = cleaned
    stack[idx] = cleaned

    # reset deeper levels when a higher one changes
    ((idx + 1)...stack.size).each { |j| stack[j] = nil }
  end

  next if level_changed.nil? # empty / spacer rows

  new_name_raw = row[NEW_NAME_COL]
  new_name = normalize_space(new_name_raw)
  old_name = normalize_space(level_name)

  next if new_name.empty?

  if old_name == new_name
    skipped_same += 1
    next
  end

  # Build path components up to current level
  path_parts = stack.compact
  # Find record by walking parent->child
  parent_id = nil
  current = nil

  path_parts.each do |part|
    part = normalize_space(part)
    # If this part was already renamed earlier under same parent, try the new name too
    cached_new = renamed_cache["#{parent_id}|#{part}"]

    # Use parent_ids column with JSON/Text search instead of parent_id
    # Since parent_ids is a serialized JSON array, we need to be careful.
    # For top level, parent_id is nil.
    candidates =
      if parent_id.nil?
        # Top level categories (no parents)
        # Search by name (PL) or translated_name (RU)
        Category.top_level.where(name: [part, cached_new].compact)
                .or(Category.top_level.where(translated_name: [part, cached_new].compact)).to_a
      else
        # Child categories.
        # Search by name (PL) or translated_name (RU)
        Category.where(
          "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
          "%\"#{parent_id}\"%",
          "%#{parent_id}%"
        ).where(name: [part, cached_new].compact)
         .or(Category.where(
          "parent_ids::text LIKE ? OR parent_ids::text LIKE ?",
          "%\"#{parent_id}\"%",
          "%#{parent_id}%"
        ).where(translated_name: [part, cached_new].compact)).to_a
      end

    if candidates.empty?
      current = nil
      break
    end

    if candidates.size > 1
      current = :ambiguous
      break
    end

    current = candidates.first
    parent_id = current.id
  end

  if current.nil?
    not_found << { row: r, path: path_parts.join(" / "), old: old_name, new: new_name }
    next
  end

  if current == :ambiguous
    ambiguous << { row: r, path: path_parts.join(" / "), old: old_name, new: new_name }
    next
  end

  planned += 1

  attrs = { name: new_name }
  attrs[:seo_name] = new_name if has_seo_name
  attrs[:h1] = new_name if has_h1

  puts "[#{APPLY ? "APPLY" : "PLAN"}] id=#{current.id} path='#{path_parts.join(" / ")}' : '#{current.translated_name}' -> '#{new_name}'"

  if APPLY
    Category.transaction do
      # Update translated_name instead of name
      safe_update!(current, { translated_name: new_name })
    end
    applied += 1
  end

  # cache rename for future traversal under this parent
  # current.parent_ids might contain multiple IDs, we need the immediate parent
  # but for simplicity of the script's logic, we use the parent_id we just used to find it
  renamed_cache["#{parent_id}|#{old_name}"] = new_name
end

# ====== REPORT ======
puts "\n" + "="*40
puts "📊 ИТОГО / SUMMARY"
puts "="*40
puts "✅ Успешно обновлено:   #{applied}"
puts "⏭️ Пропущено (совпадает): #{skipped_same}"
puts "🔍 Не найдено в базе:    #{not_found.size}"
puts "⚠️ Неоднозначно:         #{ambiguous.size}"
puts "📝 Всего строк в Excel:  #{planned + skipped_same + not_found.size + ambiguous.size}"
puts "="*40

if not_found.any?
  puts "\n--- NOT FOUND (first 30) ---"
  not_found.first(30).each do |x|
    puts "row=#{x[:row]} path='#{x[:path]}' old='#{x[:old]}' new='#{x[:new]}'"
  end
  puts "----------------------------"
end

if ambiguous.any?
  puts "\n--- AMBIGUOUS (first 30) ---"
  ambiguous.first(30).each do |x|
    puts "row=#{x[:row]} path='#{x[:path]}' old='#{x[:old]}' new='#{x[:new]}'"
  end
  puts "----------------------------"
end

puts "\nDone."
