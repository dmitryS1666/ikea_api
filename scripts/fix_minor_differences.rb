require 'json'
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))
all_db_categories = Category.all.to_a
STOP_WORDS = Set.new(%w[и в с до на для по у к])

# Manual mapping for common translations
MAPPING = {
  'Книжные шкафы и стеллажи' => 'Книжные шкафы и полки',
  'Тумбы под телевизор' => 'Таблицы RTV',
  'Комоды и тумбы' => 'Комоды и тумбочки',
  'Книжные шкафы и стеллажи' => 'Библиотеки и стеллажи',
  'Тумбы под телевизор' => 'Stoliki RTV',
  'Комоды и тумбы' => 'Komody i szafki nocne'
}

def normalize(str)
  str.to_s.downcase.gsub(/[^\w\sа-яА-ЯёЁ]/, ' ').strip
end

def similarity(s1, s2)
  w1 = normalize(s1).split - STOP_WORDS.to_a
  w2 = normalize(s2).split - STOP_WORDS.to_a
  return 0 if w1.empty? || w2.empty?
  (w1 & w2).size.to_f / (w1 | w2).size
end

matched_ikea_ids = Set.new
def collect_matches(obj, ids); obj.each{|k,v| next if k == '_value' || k == 'ikea_id'; if v.is_a?(Hash); ids.add(v['ikea_id']) if v['ikea_id']; collect_matches(v, ids); end}; end
collect_matches(json_data, matched_ikea_ids)

updates = []
def traverse(obj, db_cats, matched_ids, updates)
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      unless val['ikea_id']
        target = val['_value']
        # Try manual mapping
        match_name = MAPPING[target]
        match = db_cats.find { |c| !matched_ids.include?(c.ikea_id) && (c.translated_name == match_name || c.name == match_name) }
        
        # If not found, try high word-based similarity (>0.5) if names are long
        unless match
          best_match = nil; max_sim = 0
          db_cats.each do |c|
            next if matched_ids.include?(c.ikea_id)
            sim = similarity(target, c.translated_name)
            if sim > max_sim; max_sim = sim; best_match = c; end
          end
          if max_sim >= 0.5
            match = best_match
          end
        end

        if match
          old = match.translated_name
          match.update!(translated_name: target)
          updates << { id: match.ikea_id, old: old, new: target }
          val['ikea_id'] = match.ikea_id
          matched_ids.add(match.ikea_id)
        end
      end
      traverse(val, db_cats, matched_ids, updates)
    end
  end
end

traverse(json_data, all_db_categories, matched_ikea_ids, updates)
puts "Updated: #{updates.size}"
updates.each { |u| puts "ID #{u[:id]}: #{u[:old]} -> #{u[:new]}" }
File.write(json_path, JSON.pretty_generate(json_data))
