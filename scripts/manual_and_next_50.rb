require 'json'

# Path to the JSON file
json_path = '/home/sushi/Documents/ikea_api/Наш файл с каталогом Ikeya - Без удаленных категорий.json'
json_data = JSON.parse(File.read(json_path))

# Manual mapping (some might be partial or have typos)
MAPPING = {
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
      match_id = pairs.find { |k, v| target.include?(k) || k.include?(target) }&.last
      
      if match_id && !val['ikea_id']
        val['ikea_id'] = match_id
        cat = Category.find_by(ikea_id: match_id)
        if cat
          cat.update!(translated_name: target)
          updates << "Applied: '#{target}' linked to #{match_id}"
        end
      end
      traverse_and_apply(val, pairs, updates)
    end
  end
end

updates = []
traverse_and_apply(json_data, MAPPING, updates)
File.write(json_path, JSON.pretty_generate(json_data))

# Generate NEXT TOP 50
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
  top_matches << { gap: gap, db_name: best.translated_name, id: best.ikea_id, score: max } if best
end

top_matches.sort_by! { |m| -m[:score] }

puts "\nNEXT TOP 50 SUGGESTIONS:"
top_matches.first(50).each do |m|
  puts "#{m[:gap]}\t#{m[:id]}: #{m[:db_name]} (score: #{m[:score].round(2)})"
end
