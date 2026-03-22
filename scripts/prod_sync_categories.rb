require 'json'

# This script synchronizes the Category database with the provided master JSON structure.
# It updates names, hierarchy (parent_ids), and destroys categories not in the new tree.

final_json_path = 'ikeya_categories_final_with_merges_and_deletions.json'

unless File.exist?(final_json_path)
  puts "Error: #{final_json_path} not found."
  exit 1
end

puts "Loading master structure from #{final_json_path}..."
final_data = JSON.parse(File.read(final_json_path))

active_ids = []
stats = { updated: 0, created: 0, destroyed: 0 }

def sync_category(cat, parent_ids, active_ids, stats)
  id = cat['ikea_id']
  name = cat['effective_name']
  
  if id
    active_ids << id
    db_cat = Category.find_by(ikea_id: id)
    
    if db_cat
      db_cat.update!(
        translated_name: name,
        parent_ids: parent_ids,
        is_deleted: false
      )
      stats[:updated] += 1
    else
      Category.create!(
        ikea_id: id,
        translated_name: name,
        name: name,
        parent_ids: parent_ids,
        is_deleted: false
      )
      stats[:created] += 1
    end
    
    # Recurse for children
    if cat['children'] && cat['children'].any?
      cat['children'].each do |child|
        sync_category(child, parent_ids + [id], active_ids, stats)
      end
    end
  else
    # If node has no ID, we still process children but keep the same parent path (flattening)
    if cat['children'] && cat['children'].any?
      cat['children'].each do |child|
        sync_category(child, parent_ids, active_ids, stats)
      end
    end
  end
end

puts "Starting database synchronization..."
Category.transaction do
  final_data['categories'].each do |root_cat|
    sync_category(root_cat, [], active_ids, stats)
  end

  # Destroy categories not in the new tree
  to_destroy = Category.where.not(ikea_id: active_ids)
  stats[:destroyed] = to_destroy.count
  to_destroy.destroy_all
end

puts "\nSYNCHRONIZATION COMPLETE:"
puts "--------------------------"
puts "Categories updated: #{stats[:updated]}"
puts "Categories created: #{stats[:created]}"
puts "Categories destroyed: #{stats[:destroyed]}"
puts "Total active categories: #{Category.count}"
puts "--------------------------"
puts "Note: Please run product re-sync after this operation."
