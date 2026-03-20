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
        original_name: cat['original_name'],
        row: cat['row']
      }
    end
    traverse_missing(cat['children'], list) if cat['children']
  end
end

traverse_missing(final_data['categories'], missing_id_categories)

# Remove duplicates (some categories might appear multiple times due to merges or structure)
unique_missing = missing_id_categories.uniq { |c| c[:name] }.sort_by { |c| c[:name] }

puts "Total unique categories without ID: #{unique_missing.size}"
puts "\nLIST OF CATEGORIES WITHOUT ID:"
puts "--------------------------------"
unique_missing.each_with_index do |cat, index|
  puts "#{index + 1}. #{cat[:name]} (Оригинал: #{cat[:original_name]}, Строка в Excel: #{cat[:row]})"
end

# Also save to a file for convenience
output_path = '/home/sushi/Documents/ikea_api/missing_ids_final_report.txt'
File.write(output_path, unique_missing.map { |c| "#{c[:name]} (Оригинал: #{c[:original_name]})" }.join("\n"))
puts "\nFull list also saved to: #{output_path}"
