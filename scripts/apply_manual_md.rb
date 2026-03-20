require 'json'

# Paths
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
md_path = '/home/sushi/Documents/ikea_api/unmatched_categories_table.md'

# 1. Parse the Markdown table for mappings
mappings = {}
File.readlines(md_path).each do |line|
  next unless line.include?('✅ Сопоставлено')
  
  # Regex to capture: | Name | Status | ID |
  # ID might be in backticks, and might contain multiple IDs separated by /
  if line =~ /\|\s*(.*?)\s*\|\s*✅ Сопоставлено\s*\|\s*`?(.*?)`?\s*\|/
    name = $1.strip
    id_part = $2.strip
    
    # Handle multiple IDs like "19143 / 700675" - take the first one
    id = id_part.split('/').first.strip
    
    mappings[name] = id if id && !id.empty?
  end
end

puts "Found #{mappings.size} manual mappings in the table."

# 2. Load JSON data
json_data = JSON.parse(File.read(json_path))

# 3. Update DB and JSON
updates_db = 0
not_found_db = []

def traverse_and_apply(obj, mappings)
  applied = 0
  obj.each do |key, value|
    next if key == '_value' || key == 'ikea_id'
    
    if value.is_a?(Hash) && value['_value']
      target_name = value['_value']
      
      if mappings.key?(target_name) && !value['ikea_id']
        ikea_id = mappings[target_name]
        value['ikea_id'] = ikea_id
        applied += 1
        
        # We will handle DB update separately to avoid repeating it for duplicates in JSON
      end
      applied += traverse_and_apply(value, mappings)
    end
  end
  applied
end

json_updates = traverse_and_apply(json_data, mappings)

# 4. Sync Database
mappings.each do |json_name, ikea_id|
  cat = Category.find_by(ikea_id: ikea_id)
  if cat
    cat.update!(translated_name: json_name)
    updates_db += 1
  else
    not_found_db << "#{ikea_id} (#{json_name})"
  end
end

# 5. Save JSON
File.write(json_path, JSON.pretty_generate(json_data))

# 6. Final Stats
def calc_stats(obj)
  m, u, total = 0, 0, 0
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash) && v['_value']
      total += 1
      if v['ikea_id']
        m += 1
      else
        u += 1
      end
      cm, cu, ct = calc_stats(v)
      m += cm; u += cu; total += ct
    end
  end
  [m, u, total]
end

m, u, total = calc_stats(json_data)

puts "\nRESULTS:"
puts "Mappings from MD: #{mappings.size}"
puts "DB Categories updated: #{updates_db}"
puts "JSON nodes updated: #{json_updates}"
if not_found_db.any?
  puts "IDs not found in DB: #{not_found_db.size}"
  # puts not_found_db.join(", ")
end

puts "\nNEW STATISTICS:"
puts "Total nodes in JSON: #{total}"
puts "Matched: #{m} (#{(m.to_f/total*100).round(1)}%)"
puts "Unmatched: #{u} (#{(u.to_f/total*100).round(1)}%)"
