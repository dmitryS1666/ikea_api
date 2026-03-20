require 'csv'
require 'json'

# Paths
csv_path = '/home/sushi/Documents/ikea_api/all_db_categories_export.csv (Copy 1)'
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'

# 1. Build Name -> ID map from the CSV
csv_map = {}
CSV.foreach(csv_path, col_sep: "|", headers: true) do |row|
  name = row['translated_name (RU)'].to_s.strip
  id = row['ikea_id'].to_s.strip
  csv_map[name] = id if name && id && !id.empty?
end

puts "Loaded #{csv_map.size} mappings from CSV."

# 2. Load Final JSON
final_data = JSON.parse(File.read(final_json_path))

# 3. Try to fill missing IDs
stats = { updated: 0, already_had: 0, total: 0 }

def refill_from_csv(categories, csv_map, stats)
  categories.each do |cat|
    stats[:total] += 1
    name = cat['effective_name'].to_s.strip
    
    if cat['ikea_id']
      stats[:already_had] += 1
    elsif csv_map[name]
      cat['ikea_id'] = csv_map[name]
      stats[:updated] += 1
      # puts "Found ID for: #{name} -> #{cat['ikea_id']}"
    end
    
    refill_from_csv(cat['children'], csv_map, stats) if cat['children']
  end
end

refill_from_csv(final_data['categories'], csv_map, stats)

puts "\nMATCHING RESULTS:"
puts "Total nodes in JSON: #{stats[:total]}"
puts "Already had ID: #{stats[:already_had]}"
puts "Newly matched from CSV: #{stats[:updated]}"
puts "Remaining without ID: #{stats[:total] - stats[:already_had] - stats[:updated]}"

# 4. Save updated JSON
File.write(final_json_path, JSON.pretty_generate(final_data))
puts "\nUpdated final JSON saved."

# 5. Sync Database
# We need to make sure the DB is aware of these names and hierarchy
puts "\nSynchronizing database hierarchy..."

# Run the sync script we used before
system("bundle exec rails runner scripts/sync_final_hierarchy.rb")
