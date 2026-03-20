require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

MANUAL_PAIRS = {
  'Лотки для столовых приборов' => '15947',
  'Офисные столы' => '20649',
  'Книжные полки' => '10382',
  'Духовые шкафы METOD' => '50383',
  'Встраиваемые холодильники' => '50388',
  'Геймерские столы' => '47424',
  'Декор' => 'de001',
  'Десткие стульчики' => 'bc004',
  'Все товары BOAXEL' => '47395',
  'Все товары BROR' => '42246',
  'Аксессуары для RELATERA' => '700564',
  'Аксессуары для ванной и товары для спа' => '700339',
  'Аксессуары для кухни METOD' => '50382',
  '2-местные диваны-кровати' => '700629'
}

def traverse_and_apply(obj, pairs, updates)
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      target = val['_value']
      if pairs[target] && !val['ikea_id']
        ikea_id = pairs[target]
        val['ikea_id'] = ikea_id
        
        cat = Category.find_by(ikea_id: ikea_id)
        if cat
          old_name = cat.translated_name
          cat.update!(translated_name: target)
          updates << "Match: '#{target}' linked to #{ikea_id} (old name: '#{old_name}')"
        else
          updates << "Error: Category with ID #{ikea_id} not found in DB for '#{target}'"
        end
      end
      traverse_and_apply(val, pairs, updates)
    end
  end
end

updates = []
traverse_and_apply(json_data, MANUAL_PAIRS, updates)

puts updates.join("\n")

# Save the updated JSON
File.write(json_path, JSON.pretty_generate(json_data))
puts "\nUpdated JSON saved."
