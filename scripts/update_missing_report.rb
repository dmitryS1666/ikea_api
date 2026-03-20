require 'json'

# Path to the final JSON file
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'
final_data = JSON.parse(File.read(final_json_path))

missing_id_categories = []

def traverse_missing(categories, list)
  categories.each do |cat|
    if cat['ikea_id'].nil? || cat['ikea_id'].to_s.strip.empty?
      list << {
        name: cat['effective_name'],
        original_name: cat['original_name']
      }
    end
    traverse_missing(cat['children'], list) if cat['children']
  end
end

traverse_missing(final_data['categories'], missing_id_categories)

# Remove duplicates and sort
unique_missing = missing_id_categories.uniq { |c| c[:name] }.sort_by { |c| c[:name] }

# Save to the report file
output_path = '/home/sushi/Documents/ikea_api/missing_ids_final_report.txt'
File.open(output_path, "w") do |f|
  f.puts "СПИСОК КАТЕГОРИЙ БЕЗ IKEA ID (ФИНАЛЬНЫЙ)"
  f.puts "Всего осталось: #{unique_missing.size}"
  f.puts "----------------------------------------"
  unique_missing.each_with_index do |cat, index|
    f.puts "#{index + 1}. #{cat[:name]} (Оригинал: #{cat[:original_name]})"
  end
end

puts "Updated: #{output_path}"
puts "Total missing: #{unique_missing.size}"
