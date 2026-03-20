require 'json'

# Path to the MASTER structure file
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'
final_data = JSON.parse(File.read(final_json_path))

# 1. Synchronize Database Hierarchy from the JSON
puts "Synchronizing database hierarchy from final JSON..."

active_ids = Set.new
db_stats = { updated: 0, created: 0, deleted: 0 }

def sync_db(categories, parent_ids, active_ids, db_stats)
  categories.each do |cat|
    id = cat['ikea_id']
    name = cat['effective_name']
    
    if id
      active_ids.add(id)
      db_cat = Category.find_by(ikea_id: id)
      
      if db_cat
        db_cat.update!(
          translated_name: name,
          parent_ids: parent_ids,
          is_deleted: false
        )
        db_stats[:updated] += 1
      else
        Category.create!(
          ikea_id: id,
          translated_name: name,
          name: name,
          parent_ids: parent_ids,
          is_deleted: false
        )
        db_stats[:created] += 1
      end
      
      # Recurse with current ID added to parent_ids for children
      sync_db(cat['children'], parent_ids + [id], active_ids, db_stats) if cat['children']
    else
      # If no ID, we still recurse but with same parent_ids
      sync_db(cat['children'], parent_ids, active_ids, db_stats) if cat['children']
    end
  end
end

sync_db(final_data['categories'], [], active_ids, db_stats)

# 2. Mark categories NOT in the new tree as deleted
deleted_count = Category.where.not(ikea_id: active_ids.to_a).update_all(is_deleted: true)
db_stats[:deleted] = deleted_count

puts "\nDB SYNC COMPLETE:"
puts "Categories updated: #{db_stats[:updated]}"
puts "Categories created: #{db_stats[:created]}"
puts "Categories marked deleted: #{db_stats[:deleted]}"
puts "Total active categories in DB: #{Category.where(is_deleted: false).count}"

# --- Final Stats for the JSON ---
matched_count = 0
total_count = 0

def calc_json_stats(categories)
  m, total = 0, 0
  categories.each do |cat|
    total += 1
    m += 1 if cat['ikea_id']
    child_m, child_total = calc_json_stats(cat['children']) if cat['children']
    m += (child_m || 0)
    total += (child_total || 0)
  end
  [m, total]
end

m, total = calc_json_stats(final_data['categories'])
puts "\nFINAL JSON STATISTICS:"
puts "Total categories in tree: #{total}"
puts "Matched with IKEA ID: #{m} (#{(m.to_f/total*100).round(1)}%)"
puts "Missing IKEA ID: #{total - m}"
