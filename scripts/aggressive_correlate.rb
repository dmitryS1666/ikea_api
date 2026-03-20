require 'csv'
require 'json'
require 'set'

# Paths
csv_path = '/home/sushi/Documents/ikea_api/all_db_categories_export.csv (Copy 1)'
final_json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'

# 1. Load CSV data into an array of hashes
db_cats = []
CSV.foreach(csv_path, col_sep: "|", headers: true) do |row|
  db_cats << {
    id: row['ikea_id'],
    t_name: row['translated_name (RU)'],
    name: row['name (Original/PL)']
  }
end

# 2. Matching helpers
STOP_WORDS = Set.new(%w[и в с до на для по у к])
ENDINGS = %w[ами ями ов ей а я о е и ы].sort_by { |e| -e.length }

def stem(word)
  w = word.to_s.downcase.gsub(/[^\wа-яА-ЯёЁ]/, '')
  ENDINGS.each do |e|
    if w.end_with?(e) && w.length > e.length + 2
      return w[0...-e.length]
    end
  end
  w
end

def normalize(str)
  str.to_s.downcase.split.map { |w| stem(w) }.reject { |w| STOP_WORDS.include?(w) || w.empty? }
end

def similarity(s1, s2)
  w1 = normalize(s1)
  w2 = normalize(s2)
  return 0 if w1.empty? || w2.empty?
  
  intersection = (w1 & w2).size
  union = (w1 | w2).size
  
  score = intersection.to_f / union
  
  # Bonus if one set of stems is entirely contained in another
  if (w1 - w2).empty? || (w2 - w1).empty?
    score += 0.3
  end
  
  score
end

# 3. Load JSON
json_data = JSON.parse(File.read(final_json_path))

# 4. Collect already matched IDs to avoid duplicates
matched_ids = Set.new
def collect_ids(categories, ids)
  categories.each do |cat|
    ids.add(cat['ikea_id']) if cat['ikea_id']
    collect_ids(cat['children'], ids) if cat['children']
  end
end
collect_ids(json_data['categories'], matched_ids)

# 5. Aggressive matching
updates = []

def match_recursive(categories, db_cats, matched_ids, updates)
  categories.each do |cat|
    if cat['ikea_id'].nil? || cat['ikea_id'].to_s.empty?
      target = cat['effective_name']
      orig = cat['original_name']
      
      best_match = nil
      max_sim = 0
      
      db_cats.each do |db_cat|
        next if matched_ids.include?(db_cat[:id])
        
        sim_t = similarity(target, db_cat[:t_name])
        sim_o = similarity(orig, db_cat[:t_name])
        sim_orig_name = similarity(orig, db_cat[:name])
        
        sim = [sim_t, sim_o, sim_orig_name].max
        
        if sim > max_sim
          max_sim = sim
          best_match = db_cat
        end
      end
      
      if max_sim >= 0.6
        cat['ikea_id'] = best_match[:id]
        matched_ids.add(best_match[:id])
        updates << "Match: '#{target}' -> #{best_match[:id]} ('#{best_match[:t_name]}') [Score: #{max_sim.round(2)}]"
        
        # Update DB name to match JSON effective name
        c = Category.find_by(ikea_id: best_match[:id])
        c.update!(translated_name: target) if c
      end
    end
    match_recursive(cat['children'], db_cats, matched_ids, updates) if cat['children']
  end
end

match_recursive(json_data['categories'], db_cats, matched_ids, updates)

puts "New matches found: #{updates.size}"
updates.each { |u| puts u }

# 6. Save JSON
File.write(final_json_path, JSON.pretty_generate(json_data))

# 7. Final Hierarchy Sync
puts "\nRunning final hierarchy sync..."
system("bundle exec rails runner scripts/sync_final_hierarchy.rb")
