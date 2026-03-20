require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# 1. Collect all matched IDs and all gaps in JSON
matched_ids_in_json = Set.new
gaps_in_json = []

def traverse_json(obj, matched_ids, gaps)
  obj.each do |key, value|
    next if key == '_value' || key == 'ikea_id'
    
    if value.is_a?(Hash) && value['_value']
      if value['ikea_id']
        matched_ids.add(value['ikea_id'])
      else
        gaps << value['_value']
      end
      traverse_json(value, matched_ids, gaps)
    end
  end
end

traverse_json(json_data, matched_ids_in_json, gaps_in_json)
gaps_unique = gaps_in_json.uniq.sort

# 2. Get all unused categories from DB
unused_in_db = Category.where.not(ikea_id: matched_ids_in_json.to_a).order(:translated_name).pluck(:ikea_id, :translated_name)

# 3. Create a summary structure
summary = {
  gaps_in_json_count: gaps_unique.size,
  gaps_in_json_total: gaps_in_json.size,
  unused_in_db_count: unused_in_db.size,
  gaps_sample: gaps_unique.first(50),
  unused_sample: unused_in_db.first(50).map { |id, name| "#{id}: #{name}" }
}

puts JSON.pretty_generate(summary)
