require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# Manual mapping
MANUAL_MAPPING = {
  'Ламинированные столешницы под заказ' => '700427',
  'Система METOD' => '23598',
  'Шторы блэкаут' => '700219',
  'Римские шторы' => '700224',
  'Зеркала напольные' => '49139',
  'Сковороды-гриль' => '22664',
  'Круглые коврики' => '20543',
  'Противоскользящие коврики под ковролин' => '10699',
  'Освещение, подсветка для кухни METOD' => '50002',
  'Детские полотценца и аксессуары' => '18700',
  'Уход за новорожденными и гигиена ребенка' => '18701',
  'Холодильники и морозильные камеры ENHET' => '50379',
  'Стиральные машины и сушилки METOD' => '50390',
  'Контейнеры и ящики для хранения TROTTEN' => '55992',
  'Раковины, мойки, краны и смесители для кухни' => '700536',
  'Наборы рабочих столов и кресел' => '53249',
  'Шезлонги для отдыха' => '700350'
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
traverse_and_apply(json_data, MANUAL_MAPPING, updates)
File.write(json_path, JSON.pretty_generate(json_data))

puts updates.join("\n")

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
puts "\nSTATISTICS:"
puts "Total nodes in JSON: #{total}"
puts "Matched: #{m} (#{(m.to_f/total*100).round(1)}%)"
puts "Unmatched: #{u} (#{(u.to_f/total*100).round(1)}%)"

# Remaining
puts "\nREMAINING UNMATCHED CATEGORIES:"
def list_unmatched(obj, list)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash) && v['_value']
      list << v['_value'] unless v['ikea_id']
      list_unmatched(v, list)
    end
  end
end
unmatched_list = []
list_unmatched(json_data, unmatched_list)
puts unmatched_list.uniq.sort.join("\n")
