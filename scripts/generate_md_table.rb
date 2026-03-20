require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# 1. Collect all matched IDs from JSON
matched_ids = Set.new
def collect_ids(obj, ids)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash)
      ids.add(v['ikea_id']) if v['ikea_id']
      collect_ids(v, ids)
    end
  end
end
collect_ids(json_data, matched_ids)

# 2. Get unmatched categories from DB
unused_db = Category.where.not(ikea_id: matched_ids.to_a).order(:translated_name).pluck(:ikea_id, :translated_name)

# 3. Get all unmatched items from JSON
unmatched_json = []
def collect_unmatched_json(obj, list)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash) && v['_value']
      list << v['_value'] unless v['ikea_id']
      collect_unmatched_json(v, list)
    end
  end
end
collect_unmatched_json(json_data, unmatched_json)
unmatched_json = unmatched_json.uniq.sort

# 4. Generate Markdown table
md_content = "# Сводная таблица нераспределенных категорий\n\n"
md_content << "Используйте эту таблицу для ручного сопоставления. Вы можете копировать `ikea_id` из правой колонки в JSON-файл для соответствующих категорий из левой колонки.\n\n"

md_content << "## 1. Пробелы в JSON (нужно найти ID)\n"
md_content << "| Название в JSON | Статус | Ручной ID (заполните) |\n"
md_content << "| :--- | :--- | :--- |\n"
unmatched_json.each do |name|
  md_content << "| #{name} | ❌ Не сопоставлено | | \n"
end

md_content << "\n\n## 2. Свободные категории в БД (доступные ID)\n"
md_content << "| ikea_id | Название в БД (текущее) | Оригинальное имя (name) |\n"
md_content << "| :--- | :--- | :--- |\n"

# Fetching original names too for better context
unused_db_full = Category.where.not(ikea_id: matched_ids.to_a).order(:translated_name).pluck(:ikea_id, :translated_name, :name)
unused_db_full.each do |id, t_name, name|
  md_content << "| `#{id}` | #{t_name} | #{name} |\n"
end

File.write('/home/sushi/Documents/ikea_api/unmatched_categories_table.md', md_content)
puts "Markdown table generated: /home/sushi/Documents/ikea_api/unmatched_categories_table.md"
