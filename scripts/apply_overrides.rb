require 'json'

# Path to the MASTER structure file
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'
final_data = JSON.parse(File.read(final_json_path))

# Manual overrides provided by the user
OVERRIDES = {
  'Диваны нераскладные' => 'fu003',
  'Готовые комбинации кухонь METOD' => '50005',
  'Модуальная садовая мебель' => '21960',
  'Навесные шкафы в ванную комнату' => '20808'
}

# 1. Apply overrides to JSON
def apply_overrides(categories, overrides, stats)
  categories.each do |cat|
    name = cat['effective_name'].to_s.strip
    if overrides.key?(name)
      cat['ikea_id'] = overrides[name]
      stats[:updated] += 1
    end
    apply_overrides(cat['children'], overrides, stats) if cat['children']
  end
end

stats = { updated: 0 }
apply_overrides(final_data['categories'], OVERRIDES, stats)
File.write(final_json_path, JSON.pretty_generate(final_data))
puts "Applied #{stats[:updated]} manual overrides in JSON."

# 2. Update Database Names for these IDs to avoid confusion in future syncs
OVERRIDES.each do |json_name, ikea_id|
  cat = Category.find_by(ikea_id: ikea_id)
  if cat
    cat.update!(translated_name: json_name)
    puts "DB Updated: ID #{ikea_id} is now '#{json_name}'"
  else
    # Create if missing
    Category.create!(ikea_id: ikea_id, translated_name: json_name, name: json_name)
    puts "DB Created: ID #{ikea_id} as '#{json_name}'"
  end
end

# 3. Final Hierarchy Sync to cleanup parent_ids and is_deleted flags
puts "\nRunning final sync to align everything..."
system("bundle exec rails runner scripts/final_db_sync.rb")
