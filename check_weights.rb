count_with_weight = Product.where("full_attributes_ru->'detailed_info' ? 'Вес'").count
total_count = Product.count
puts "Products with 'Вес' in detailed_info: #{count_with_weight} out of #{total_count}"

# Find examples of products with 'Вес' containing 'гр'
examples = Product.where("full_attributes_ru->'detailed_info'->>'Вес' LIKE '%гр%'").limit(5).pluck(:sku, :name_ru, :weight, "full_attributes_ru->'detailed_info'->>'Вес'")
puts "\nExamples with 'гр' in 'Вес':"
examples.each { |e| puts e.join(' | ') }
