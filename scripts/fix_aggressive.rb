require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# 1. Collect currently matched IDs to avoid reusing them
matched_ikea_ids = Set.new
def collect_matched(obj, ids)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash)
      ids.add(v['ikea_id']) if v['ikea_id']
      collect_matched(v, ids)
    end
  end
end
collect_matched(json_data, matched_ikea_ids)

# 2. Get unmatched categories from DB
unmatched_db_cats = Category.where.not(ikea_id: matched_ikea_ids.to_a).to_a

# 3. Helper for even softer matching
STOP_WORDS = Set.new(%w[и в с до на для по у к])
# Common Russian endings to strip for "pseudo-stemming"
ENDINGS = %w[ами ями ов ей а я о е и ы].sort_by { |e| -e.length }

def stem(word)
  w = word.downcase.gsub(/[^\wа-яА-ЯёЁ]/, '')
  ENDINGS.each do |e|
    if w.end_with?(e) && w.length > e.length + 2
      return w[0...-e.length]
    end
  end
  w
end

def soft_normalize(str)
  str.to_s.downcase.split.map { |w| stem(w) }.reject { |w| STOP_WORDS.include?(w) || w.empty? }
end

def deep_similarity(s1, s2)
  w1 = soft_normalize(s1)
  w2 = soft_normalize(s2)
  return 0 if w1.empty? || w2.empty?
  
  intersection = (w1 & w2).size
  union = (w1 | w2).size
  
  # Basic Jaccard on stems
  score = intersection.to_f / union
  
  # Bonus if one is a subset
  if (w1 - w2).empty? || (w2 - w1).empty?
    score += 0.2
  end
  
  score
end

# 4. Traversal and aggressive matching
updates = []
def traverse_and_aggressive_fix(obj, db_cats, matched_ids, updates)
  obj.each do |key, value|
    next if key == '_value' || key == 'ikea_id'
    
    if value.is_a?(Hash) && value['_value']
      unless value['ikea_id']
        target_name = value['_value']
        
        best_match = nil
        max_sim = 0
        
        db_cats.each do |cat|
          next if matched_ids.include?(cat.ikea_id)
          
          sim = deep_similarity(target_name, cat.translated_name)
          if sim > max_sim
            max_sim = sim
            best_match = cat
          end
        end
        
        # Using a lower threshold for "aggressive" matching, but with sanity check
        if max_sim >= 0.5
          # Final sanity check: at least one word must match significantly
          match_found = false
          t_stems = soft_normalize(target_name)
          m_stems = soft_normalize(best_match.translated_name)
          if (t_stems & m_stems).any?
             match_found = true
          end

          if match_found
            old_name = best_match.translated_name
            best_match.update!(translated_name: target_name)
            updates << { id: best_match.ikea_id, old: old_name, new: target_name, sim: max_sim }
            value['ikea_id'] = best_match.ikea_id
            matched_ids.add(best_match.ikea_id)
          end
        end
      end
      
      traverse_and_aggressive_fix(value, db_cats, matched_ids, updates)
    end
  end
end

puts "Starting aggressive matching for remaining categories..."
traverse_and_aggressive_fix(json_data, unmatched_db_cats, matched_ikea_ids, updates)

puts "Aggressive updates made: #{updates.size}"
updates.each do |u|
  puts "Matched: ID #{u[:id]}: '#{u[:old]}' -> '#{u[:new]}' (score: #{u[:sim].round(2)})"
end

# Save the updated JSON
File.write(json_path, JSON.pretty_generate(json_data))
puts "\nUpdated JSON saved at: #{json_path}"
