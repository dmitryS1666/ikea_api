require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# Load all categories from the DB
db_by_translated = {}
Category.all.each do |cat|
  t_name = cat.translated_name.to_s.strip.downcase
  db_by_translated[t_name] ||= []
  db_by_translated[t_name] << cat
end

def traverse_and_clean(json_obj, db_by_translated)
  json_obj.each do |key, value|
    next if key == '_value' || key == 'ikea_id'
    
    if value.is_a?(Hash) && value['_value']
      target_name = value['_value'].to_s.strip.downcase
      match = db_by_translated[target_name]&.first
      
      if match
        value['ikea_id'] = match.ikea_id
      else
        value.delete('ikea_id')
      end
      
      traverse_and_clean(value, db_by_translated)
    end
  end
end

traverse_and_clean(json_data, db_by_translated)

# Save
File.write(json_path, JSON.pretty_generate(json_data))
puts "JSON cleaned to exact matches."
