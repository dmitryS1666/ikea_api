require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# Load all categories from the DB
# We'll build maps for both name and translated_name
db_by_translated = {}
db_by_name = {}

Category.all.each do |cat|
  t_name = cat.translated_name.to_s.strip.downcase
  name = cat.name.to_s.strip.downcase
  
  db_by_translated[t_name] ||= []
  db_by_translated[t_name] << cat
  
  db_by_name[name] ||= []
  db_by_name[name] << cat
end

discrepancies = []

def find_match(value, parent_ikea_ids, db_by_translated, db_by_name)
  return nil if value.nil?
  search_val = value.to_s.strip.downcase
  
  # Try translated_name first
  candidates = db_by_translated[search_val] || []
  # If not found, try name
  candidates = db_by_name[search_val] || [] if candidates.empty?
  
  return nil if candidates.empty?
  
  if candidates.size == 1
    return candidates.first
  end

  # Disambiguate by parent
  if parent_ikea_ids && !parent_ikea_ids.empty?
    candidates.each do |cat|
      p_ids = cat.parent_ids
      p_ids = JSON.parse(p_ids) if p_ids.is_a?(String)
      p_ids = Array(p_ids)
      if (p_ids & parent_ikea_ids).any?
        return cat
      end
    end
  end

  candidates.first
end

def traverse(json_obj, parent_ikea_ids, db_by_translated, db_by_name, discrepancies)
  updated_obj = {}
  json_obj.each do |key, value|
    if key == '_value'
      updated_obj['_value'] = value
      next
    end
    
    if key == 'ikea_id'
      updated_obj['ikea_id'] = value # keep existing if already updated
      next
    end

    if value.is_a?(Hash) && value['_value']
      name_val = value['_value']
      
      # If already has ikea_id from previous run, we can still try to verify or update
      match = find_match(name_val, parent_ikea_ids, db_by_translated, db_by_name)
      
      child_updated = {}
      current_ikea_ids = []
      
      if match
        child_updated['ikea_id'] = match.ikea_id
        current_ikea_ids = [match.ikea_id]
        
        # Check parent consistency
        if parent_ikea_ids && !parent_ikea_ids.empty?
          p_ids = match.parent_ids
          p_ids = JSON.parse(p_ids) if p_ids.is_a?(String)
          p_ids = Array(p_ids)
          if (p_ids & parent_ikea_ids).empty?
             # No longer adding warning to discrepancies for parent mismatch if we found it by name, 
             # but we'll log it for info
          end
        end
      else
        discrepancies << "Missing in DB: Category '#{name_val}'"
      end

      # Recurse
      res = traverse(value, current_ikea_ids, db_by_translated, db_by_name, discrepancies)
      child_updated.merge!(res)
      updated_obj[key] = child_updated
    else
      updated_obj[key] = value
    end
  end
  updated_obj
end

# The JSON might have existing ikea_id fields now
updated_json = traverse(json_data, [], db_by_translated, db_by_name, discrepancies)

# Summary
def count_stats(obj)
  m, ms = 0, 0
  if obj.is_a?(Hash)
    m += 1 if obj.has_key?('ikea_id')
    ms += 1 if obj.has_key?('_value') && !obj.has_key?('ikea_id')
    obj.each do |k, v|
      if v.is_a?(Hash)
        cm, cms = count_stats(v)
        m += cm
        ms += cms
      end
    end
  end
  [m, ms]
end

matches, missing = count_stats(updated_json)
puts "Summary:"
puts "Matches found: #{matches}"
puts "Missing in DB: #{missing}"

# Save
File.write(json_path, JSON.pretty_generate(updated_json))
puts "\nUpdated JSON saved (overwritten) at: #{json_path}"
