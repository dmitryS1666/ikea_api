require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# New manual mapping provided by the user
NEW_MAPPING = {
  'Вок-сковороды' => '20631',
  'Модульные системы шкафов PLATSA' => '37895',
  'Полы, настилы для балконов и террас' => '21957',
  'Холодильники и морозильные камеры METOD' => '50388'
}

def traverse_and_apply(obj, pairs, updates)
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      target = val['_value']
      match_id = pairs[target]
      
      if match_id && !val['ikea_id']
        val['ikea_id'] = match_id
        cat = Category.find_by(ikea_id: match_id)
        if cat
          old_name = cat.translated_name
          cat.update!(translated_name: target)
          updates << "Applied: '#{target}' linked to #{match_id} (was: '#{old_name}')"
        end
      end
      traverse_and_apply(val, pairs, updates)
    end
  end
end

updates = []
traverse_and_apply(json_data, NEW_MAPPING, updates)
File.write(json_path, JSON.pretty_generate(json_data))

puts updates.join("\n")

# --- REGENERATE MD TABLE ---

# 1. Collect all matched IDs from JSON
matched_ids = Set.new
unmatched_json = []

def traverse_final(obj, ids, gaps)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash) && v['_value']
      if v['ikea_id']
        ids.add(v['ikea_id'])
      else
        gaps << v['_value']
      end
      traverse_final(v, ids, gaps)
    end
  end
end

traverse_final(json_data, matched_ids, unmatched_json)
unmatched_json = unmatched_json.uniq.sort

# 2. Get all unused categories from DB
unused_db = Category.where.not(ikea_id: matched_ids.to_a).order(:translated_name).pluck(:ikea_id, :translated_name, :name)

# 3. Generate Markdown
md_content = "# Сводная таблица нераспределенных категорий (ОБНОВЛЕННАЯ)\n\n"
md_content << "## 1. Пробелы в JSON (нужно найти ID)\n"
md_content << "| Название в JSON | Статус | Ручной ID (заполните) |\n"
md_content << "| :--- | :--- | :--- |\n"
unmatched_json.each do |name|
  md_content << "| #{name} | ❌ Не сопоставлено | | \n"
end

md_content << "\n\n## 2. Свободные категории в БД (доступные ID)\n"
md_content << "| ikea_id | Название в БД (текущее) | Оригинальное имя (name) |\n"
md_content << "| :--- | :--- | :--- |\n"

unused_db.each do |id, t_name, name|
  md_content << "| `#{id}` | #{t_name} | #{name} |\n"
end

File.write('/home/sushi/Documents/ikea_api/unmatched_categories_table.md', md_content)
puts "\nMarkdown table regenerated: /home/sushi/Documents/ikea_api/unmatched_categories_table.md"

# Stats
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
      child_m, child_u, child_total = calc_stats(v)
      m += child_m
      u += child_u
      total += child_total
    end
  end
  [m, u, total]
end

m, u, total = calc_stats(json_data)
puts "\nNEW STATISTICS:"
puts "Total nodes in JSON: #{total}"
puts "Matched: #{m} (#{(m.to_f/total*100).round(1)}%)"
puts "Unmatched: #{u} (#{(u.to_f/total*100).round(1)}%)"
