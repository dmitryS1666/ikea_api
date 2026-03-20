require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# The 50 mappings provided by the user
MAPPINGS_50 = {
  'Контейнеры для еды и крышки' => '700610',
  'Формы для мороженого и льда' => '33500',
  'Полки и аксессуары для ванной комнаты' => '20615',
  'Товары для кошек' => '39569',
  'Крючки, полки и настенные органайзеры' => 'st006',
  'Ароматические саше для шкафов и стеллажей' => '58411',
  'Формы для выпечки' => '20645',
  'Термосы и термокружки' => '20620',
  'Наборы для пикника' => '700353',
  'Ковры и покрывала' => '20528',
  'Чехлы для садовой мебели и зонтов' => '34205',
  'Засушенные цветы, растения и попурри' => '20496',
  'Полки и ящики для кухни METOD' => '49117',
  'Ножки, опоры и основания для кухни ENHET' => '48995',
  'Детские полотценца и аксессуары' => '18700',
  'Уход за новорожденными и гигиена ребенка' => '18701',
  'Холодильники и морозильные камеры ENHET' => '50379',
  'Стиральные машины и сушилки METOD' => '50390',
  'Контейнеры и ящики для хранения TROTTEN' => '55992',
  'Обувницы и комоды для обуви' => '10456',
  'Стаканы и держатели для зубных щеток' => '48943',
  'Товары для рисования и рукоделия' => '18735',
  'Крючки для одежды' => '10459',
  'Буфеты и серванты' => '10412',
  'Раскладные столы' => '21829',
  'Миски для смешивания и взбивания' => '15935',
  'Барные столы и табуреты' => '16244',
  'Чехлы на стулья' => '25218',
  'Аксессуары для ванной без сверления' => '700699',
  'Полки со скрытым креплением' => '55014',
  'Коробки, органайзеры для хранения обуви' => '10458',
  'Магнитные и пробковые доски на стену' => '10557',
  'Контейнеры для раздельного сбора мусора' => '24259',
  'Подушка для поясницы, поддержка спины' => '54992',
  'Электрические шторы' => '55018',
  'Светодиодные ленты' => '55019',
  'Настольные лампы для улицы' => '700617',
  'Плакаты и постеры' => '10787',
  'Цифровые таймеры' => '10759',
  'Лейки, пульверизаторы и разбрызгиватели' => '33501',
  'Подставки и столики для ноутбуков' => '24830',
  'Игровые аксессуары для геймеров' => '55397',
  'Посуда для сервировки' => '18860',
  'Салфетки бумажные' => '20562',
  'Болты, винты, шурупы и крепления' => '49768',
  'Безопасность дома' => 'sp001',
  'Детские ванночки для купания' => '45924',
  'Детские комоды' => '18708',
  'Хранение игрушек в детской комнате' => '20474',
  'Двухъярусные кровати для детей' => '19048'
}

def apply_mappings(obj, mappings)
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      target_name = val['_value']
      ikea_id = mappings[target_name]
      
      if ikea_id && !val['ikea_id']
        val['ikea_id'] = ikea_id
        cat = Category.find_by(ikea_id: ikea_id)
        if cat
          cat.update!(translated_name: target_name)
        end
      end
      apply_mappings(val, mappings)
    end
  end
end

puts "Applying 50 mappings..."
apply_mappings(json_data, MAPPINGS_50)

# Save the updated JSON
File.write(json_path, JSON.pretty_generate(json_data))
puts "Updated JSON and Database."

# Calculate Statistics
total_in_json = 0
matched_in_json = 0
gaps_in_json = []

def calc_stats(obj, matched_ids, gaps)
  total = 0
  obj.each do |key, val|
    next if key == '_value' || key == 'ikea_id'
    if val.is_a?(Hash) && val['_value']
      total += 1
      if val['ikea_id']
        matched_ids.add(val['ikea_id'])
      else
        gaps << val['_value']
      end
      total += calc_stats(val, matched_ids, gaps)
    end
  end
  total
end

matched_unique_ids = Set.new
total_in_json = calc_stats(json_data, matched_unique_ids, gaps_in_json)
gaps_unique = gaps_in_json.uniq

unused_in_db = Category.where.not(ikea_id: matched_unique_ids.to_a).to_a

puts "\nSTATISTICS:"
puts "Total entries in JSON: #{total_in_json}"
puts "Matched entries in JSON: #{total_in_json - gaps_in_json.size}"
puts "Remaining gaps in JSON (unique names): #{gaps_unique.size}"
puts "Unused categories in DB: #{unused_in_db.size}"

# Generate NEXT TOP 50 Suggestions
def normalize(s); s.to_s.downcase.gsub(/[^\wа-яА-ЯёЁ]/, ' ').strip; end
def similarity(s1, s2)
  w1 = normalize(s1).split
  w2 = normalize(s2).split
  return 0 if w1.empty? || w2.empty?
  (w1 & w2).size.to_f / (w1 | w2).size
end

top_matches = []
gaps_unique.each do |gap|
  best = nil; max = 0
  unused_in_db.each do |cat|
    sim = similarity(gap, cat.translated_name)
    if sim > max; max = sim; best = cat; end
  end
  top_matches << { gap: gap, db_name: best.translated_name, id: best.ikea_id, score: max } if best
end

top_matches.sort_by! { |m| -m[:score] }

puts "\nNEXT TOP 50 SUGGESTIONS:"
top_matches.first(50).each do |m|
  puts "#{m[:gap]}\t#{m[:id]}: #{m[:db_name]} (score: #{m[:score].round(2)})"
end
