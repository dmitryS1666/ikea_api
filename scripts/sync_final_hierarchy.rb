require 'json'

# Paths
source_json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'

# 1. Build Name -> IKEA_ID mapping from the worked-on file
source_data = JSON.parse(File.read(source_json_path))
name_to_id = {}

def extract_mappings(obj, mapping)
  obj.each do |key, val|
    next if key == 'ikea_id' || key == '_value'
    if val.is_a?(Hash) && val['_value']
      name = val['_value'].to_s.strip
      id = val['ikea_id']
      mapping[name] = id if id
      extract_mappings(val, mapping)
    end
  end
end

extract_mappings(source_data, name_to_id)
puts "Extracted #{name_to_id.size} name -> id mappings."

# 2. Update the final JSON with IDs
final_data = JSON.parse(File.read(final_json_path))

def apply_ids(categories, mapping, stats)
  categories.each do |cat|
    name = cat['effective_name'].to_s.strip
    if mapping[name]
      cat['ikea_id'] = mapping[name]
      stats[:matched] += 1
    else
      stats[:missing] += 1
      # puts "Missing ID for: #{name}"
    end
    apply_ids(cat['children'], mapping, stats) if cat['children']
  end
end

stats = { matched: 0, missing: 0 }
apply_ids(final_data['categories'], name_to_id, stats)
puts "Final JSON update stats: Matched: #{stats[:matched]}, Missing: #{stats[:missing]}"

# Save updated final JSON
File.write(final_json_path, JSON.pretty_generate(final_data))
puts "Updated final JSON saved."

# 3. Synchronize Database
puts "Synchronizing database..."

# To store all IDs that are part of the new hierarchy
active_ids = Set.new

def sync_db(categories, parent_ids, active_ids, db_stats)
  categories.each do |cat|
    id = cat['ikea_id']
    name = cat['effective_name']
    
    if id
      active_ids.add(id)
      db_cat = Category.find_by(ikea_id: id)
      
      if db_cat
        # Update name and parent_ids
        # parent_ids in DB is a JSON array of IKEA IDs
        db_cat.update!(
          translated_name: name,
          parent_ids: parent_ids,
          is_deleted: false
        )
        db_stats[:updated] += 1
      else
        # If not found, we might need to create it? 
        # But for now, we only sync existing ones as per requirements.
        # Actually, let's create a minimal record if it has an ID but is missing.
        Category.create!(
          ikea_id: id,
          translated_name: name,
          name: name, # fallback
          parent_ids: parent_ids,
          is_deleted: false
        )
        db_stats[:created] += 1
      end
      
      # Recurse with current ID added to parent_ids for children
      sync_db(cat['children'], parent_ids + [id], active_ids, db_stats) if cat['children']
    else
      # If no ID, we still recurse but with same parent_ids (flattening the missing node)
      # Or we could just skip. Given the request, we skip for now but recurse.
      sync_db(cat['children'], parent_ids, active_ids, db_stats) if cat['children']
    end
  end
end

db_stats = { updated: 0, created: 0, deleted: 0 }
sync_db(final_data['categories'], [], active_ids, db_stats)

# 4. Mark categories NOT in the new tree as deleted
deleted_count = Category.where.not(ikea_id: active_ids.to_a).update_all(is_deleted: true)
db_stats[:deleted] = deleted_count

puts "\nDB SYNC COMPLETE:"
puts "Categories updated: #{db_stats[:updated]}"
puts "Categories created: #{db_stats[:created]}"
puts "Categories marked deleted: #{db_stats[:deleted]}"
puts "Total active categories in DB: #{Category.where(is_deleted: false).count}"
