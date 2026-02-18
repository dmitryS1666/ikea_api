# frozen_string_literal: true

# Usage:
#   bundle exec rails runner scripts/apply_final_categories.rb scripts/final_categories.xlsx
#
# Apply changes:
#   APPLY=1 bundle exec rails runner scripts/apply_final_categories.rb scripts/final_categories.xlsx

require "roo"

# =========================
# CONFIG
# =========================
SHEET          = ENV.fetch("SHEET", "Правки")
APPLY          = ENV["APPLY"].to_s == "1"
CATEGORY_MODEL = "Category"
JOIN_MODEL     = "CategoryProduct"
JOIN_FROM_FK   = "category_id"
JOIN_TO_FK     = "product_id"

# Columns in XLSX
COL_ROWNUM = "Номер строки ( без удаленных категорий)"
COL_CAT_ID = "ID категории"
COL_LINK   = "Ссылки"
COL_STATUS = "Статус"

# =========================
# Helpers
# =========================
def abort_with(msg)
  warn "\nERROR: #{msg}\n\n"
  exit 1
end

def norm(s)
  s.to_s.gsub(/\s+/, " ").strip
end

def string_id(v)
  return nil if v.nil?
  s = v.to_s.strip
  s.empty? ? nil : s
end

def mark_deleted!(record)
  if record.class.column_names.include?("is_deleted")
    record.update!(is_deleted: true)
  else
    record.destroy!
  end
end

def parse_merge_target(status)
  s = norm(status)
  return nil unless s.downcase.include?("схлопываем")

  if s =~ /строке\s+(\d+)/i
    return { type: :row, value: Integer($1) }
  end

  if s =~ /категор(ией|ией\s+с)\s+([a-zA-Z0-9_]+)/i
    return { type: :id, value: $2 }
  end

  nil
end

# =========================
# Boot
# =========================
file_path = ARGV[0]
abort_with("XLSX path is required") if file_path.nil? || file_path.strip.empty?
abort_with("File not found: #{file_path}") unless File.exist?(file_path)

Category = Object.const_get(CATEGORY_MODEL)
JoinModel = Object.const_get(JOIN_MODEL)

puts "== Apply Categories Rules (FIXED) =="
puts "File:   #{file_path}"
puts "Mode:   #{APPLY ? "APPLY (writes DB)" : "DRY-RUN (no DB writes)"}"
puts "============================"

xlsx = Roo::Excelx.new(file_path)
sheet = xlsx.sheet(SHEET)

headers = sheet.row(1).map(&:to_s)
idx = headers.each_with_index.to_h

missing = [COL_ROWNUM, COL_CAT_ID, COL_LINK, COL_STATUS].reject { |c| idx.key?(c) }
abort_with("Missing columns in header: #{missing.join(', ')}") unless missing.empty?

# =========================
# Pass 1: map rownum -> category_id
# =========================
rownum_to_catid = {}
(2..sheet.last_row).each do |r|
  row_data = sheet.row(r)
  rownum = row_data[idx[COL_ROWNUM]]&.to_i
  catid  = string_id(row_data[idx[COL_CAT_ID]])

  next if rownum.nil? || catid.nil?
  rownum_to_catid[rownum] = catid
end

# =========================
# Pass 2: execute
# =========================
stats = { plan_delete: 0, plan_merge: 0, plan_keep: 0, applied_delete: 0, applied_merge: 0, not_found: 0, manual_review: 0 }

def move_children!(from_id, to_id)
  # In this project, parent_ids is a serialized JSON array of strings
  # We find all categories where from_id is in parent_ids
  Category.where("parent_ids::text LIKE ?", "%\"#{from_id}\"%").each do |cat|
    new_parents = cat.parent_ids.map { |pid| pid == from_id ? to_id : pid }.uniq
    cat.update!(parent_ids: new_parents)
  end
end

def move_products!(from_id, to_id)
  # Move CategoryProduct links
  links = JoinModel.where(category_id: from_id)
  links.each do |link|
    # Check if product already linked to target category
    exists = JoinModel.where(category_id: to_id, product_id: link.product_id).exists?
    if exists
      link.destroy!
    else
      link.update!(category_id: to_id)
    end
  end
end

(2..sheet.last_row).each do |r|
  row = sheet.row(r)
  catid  = string_id(row[idx[COL_CAT_ID]])
  status = norm(row[idx[COL_STATUS]])
  link   = norm(row[idx[COL_LINK]])

  next if catid.nil?

  if status.downcase.start_with?("оставляем")
    stats[:plan_keep] += 1
    next
  end

  if status.downcase.start_with?("удаляем")
    stats[:plan_delete] += 1
    cat = Category.find_by(ikea_id: catid)
    unless cat
      stats[:not_found] += 1
      next
    end

    puts "[#{APPLY ? "APPLY" : "PLAN"}][DELETE] id=#{catid}"
    if APPLY
      Category.transaction do
        # Before deleting, we should probably move its products to parent or just let them be orphaned?
        # The user said "products should be linked to only one category, others deleted".
        # This usually means if we delete a category, its product links go away.
        mark_deleted!(cat)
      end
      stats[:applied_delete] += 1
    end
    next
  end

  merge = parse_merge_target(status)
  if merge
    stats[:plan_merge] += 1
    from_cat = Category.find_by(ikea_id: catid)
    
    target_id = (merge[:type] == :id) ? merge[:value] : rownum_to_catid[merge[:value]]
    to_cat = Category.find_by(ikea_id: target_id)

    if from_cat.nil? || to_cat.nil?
      stats[:not_found] += 1
      next
    end

    if from_cat.ikea_id == to_cat.ikea_id
      puts "[SKIP] Source and target are same: #{catid}"
      next
    end

    puts "[#{APPLY ? "APPLY" : "PLAN"}][MERGE] #{from_cat.ikea_id} -> #{to_cat.ikea_id}"
    if APPLY
      Category.transaction do
        move_products!(from_cat.ikea_id, to_cat.ikea_id)
        move_children!(from_cat.ikea_id, to_cat.ikea_id)
        mark_deleted!(from_cat)
      end
      stats[:applied_merge] += 1
    end
    next
  end

  stats[:manual_review] += 1
end

puts "\n" + "="*40
puts "📊 ИТОГО / SUMMARY"
puts "="*40
puts "✅ Успешно удалено:     #{stats[:applied_delete]}"
puts "🔄 Успешно объединено:  #{stats[:applied_merge]}"
puts "⏭️ Оставлено без изм.:  #{stats[:plan_keep]}"
puts "🔍 Не найдено в базе:   #{stats[:not_found]}"
puts "⚠️ Требует внимания:    #{stats[:manual_review]}"
puts "="*40
puts "\nDone."
