require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# 1. Collect all unmatched categories from the JSON file
unmatched_in_json = []
matched_ikea_ids = Set.new

def traverse_json(obj, unmatched_list, matched_ids)
  obj.each do |key, value|
    next if key == '_value' || key == 'ikea_id'
    
    if value.is_a?(Hash) && value['_value']
      if value['ikea_id']
        matched_ids.add(value['ikea_id'])
      else
        unmatched_list << {
          "source": "json",
          "name_in_json": key,
          "translated_name": value['_value'],
          "ikea_id": nil
        }
      end
      traverse_json(value, unmatched_list, matched_ids)
    end
  end
end

traverse_json(json_data, unmatched_in_json, matched_ikea_ids)

# 2. Find all categories in the DB that are NOT in matched_ikea_ids
unmatched_in_db = Category.where.not(ikea_id: matched_ikea_ids.to_a).map do |cat|
  {
    "source": "database",
    "name": cat.name,
    "translated_name": cat.translated_name,
    "ikea_id": cat.ikea_id
  }
end

# 3. Save both lists to a single file
report = {
  "unmatched_in_json": unmatched_in_json,
  "unmatched_in_db": unmatched_in_db
}

output_path = '/home/sushi/Documents/ikea_api/not_matched_report.json'
File.write(output_path, JSON.pretty_generate(report))

puts "Unmatched in JSON: #{unmatched_in_json.size}"
puts "Unmatched in DB: #{unmatched_in_db.size}"
puts "Report saved to: #{output_path}"
