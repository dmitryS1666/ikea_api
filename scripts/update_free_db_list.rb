require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

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
puts "Markdown table updated. Remaining gaps in JSON: #{unmatched_json.size}. Available IDs in DB: #{unused_db.size}."
