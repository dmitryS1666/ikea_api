require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# Manual mapping provided by the user
MANUAL_MAPPING = {
  'Контейнеры для хранения продуктов' => '700610',
  'Туалетные ершики и держатели для бумаги' => '48944',
  'Перегородки для стола' => '700336',
  'Столы для дома' => '10705',
  'Стулья и табуреты для балкона и террасы' => '21960',
  'Подставки и крышки для посуды' => '59251',
  'Ножки и опоры для столов' => '11845',
  'Скатерти и настольные дорожки' => '47423',
  'Прихватки, рукавицы для духовки' => '20537',
  'Высокие шкафы-пеналы METOD' => '23609',
  'Холодильники и морозильные камеры' => '20822',
  'Посудомоечные машины METOD' => '50387',
  'Диспенсеры для моющего средства' => '700195',
  'Офисные и письменные системы' => '47423',
  'Зонты, беседки и перголы' => '17887',
  'Подсветка для гардероба PLATSA' => '700609',
  'Уличные горшки и кашпо' => 'pp004',
  'Попурри, свечи и ароматические саше' => '42926',
  'Блюда, тарелки и масленки для сервировки' => '16047',
  'Подушки из полиэстера' => '20535',
  'Одеяла из полиэстера' => '20531',
  'Плиссированные шторы' => '700225',
  'Электрические шторы' => '55018',
  'Светодиодные ленты' => '55019'
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
puts "\nJSON file updated and DB names synchronized."

# --- Statistics ---
matched_count = 0
unmatched_count = 0
all_nodes = 0

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

matched_count, unmatched_count, all_nodes = calc_stats(json_data)
puts "\nSTATISTICS:"
puts "Total categories in JSON: #{all_nodes}"
puts "Matched: #{matched_count} (#{(matched_count.to_f/all_nodes*100).round(1)}%)"
puts "Unmatched: #{unmatched_count} (#{(unmatched_count.to_f/all_nodes*100).round(1)}%)"

# --- NEXT TOP 50 ---
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

unused_db = Category.where.not(ikea_id: matched_ids.to_a).to_a
gaps_in_json = []
def collect_gaps(obj, gaps)
  obj.each do |k, v|
    next if k == '_value' || k == 'ikea_id'
    if v.is_a?(Hash) && v['_value']
      gaps << v['_value'] unless v['ikea_id']
      collect_gaps(v, gaps)
    end
  end
end
collect_gaps(json_data, gaps_in_json)
gaps_in_json.uniq!

def normalize(s); s.to_s.downcase.gsub(/[^\wа-яА-ЯёЁ]/, ' ').strip; end
def similarity(s1, s2)
  w1 = normalize(s1).split
  w2 = normalize(s2).split
  return 0 if w1.empty? || w2.empty?
  (w1 & w2).size.to_f / (w1 | w2).size
end

top_matches = []
gaps_in_json.each do |gap|
  best = nil; max = 0
  unused_db.each do |cat|
    sim = similarity(gap, cat.translated_name)
    if sim > max; max = sim; best = cat; end
  end
  top_matches << { gap: gap, db_name: (best ? best.translated_name : ""), id: (best ? best.ikea_id : ""), score: max } if best
end

top_matches.sort_by! { |m| -m[:score] }

puts "\nNEXT TOP 50 SUGGESTIONS:"
top_matches.first(50).each do |m|
  puts "#{m[:gap]}\t#{m[:id]}: #{m[:db_name]} (score: #{m[:score].round(2)})"
end
