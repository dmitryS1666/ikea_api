require 'json'

final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'
final_data = JSON.parse(File.read(final_json_path))

# Build a map from DB: translated_name -> ikea_id
db_map = {}
Category.where(is_deleted: false).each do |c|
  db_map[c.translated_name.to_s.strip] = c.ikea_id
end

stats = { updated: 0, total: 0 }

def refill_ids(categories, db_map, stats)
  categories.each do |cat|
    stats[:total] += 1
    name = cat['effective_name'].to_s.strip
    if db_map[name]
      cat['ikea_id'] = db_map[name]
      stats[:updated] += 1
    end
    refill_ids(cat['children'], db_map, stats) if cat['children']
  end
end

refill_ids(final_data['categories'], db_map, stats)
File.write(final_json_path, JSON.pretty_generate(final_data))

puts "Final JSON pass from DB: Updated #{stats[:updated]} out of #{stats[:total]} nodes."
