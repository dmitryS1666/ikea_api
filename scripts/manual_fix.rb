require 'json'
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

MANUAL_MATCHES = {
  'Комоды и тумбы' => 'st004',
  'Книжные шкафы и стеллажи' => 'st002',
  'Стеллажи для хранения' => '10397'
}

def traverse_manual(obj, manual_matches)
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      target = val['_value']
      if manual_matches[target]
        ikea_id = manual_matches[target]
        val['ikea_id'] = ikea_id
        cat = Category.find_by(ikea_id: ikea_id)
        cat.update!(translated_name: target) if cat
        puts "Manually matched: #{target} -> #{ikea_id}"
      end
      traverse_manual(val, manual_matches)
    end
  end
end

traverse_manual(json_data, MANUAL_MATCHES)
File.write(json_path, JSON.pretty_generate(json_data))
