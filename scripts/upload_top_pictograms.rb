require 'find'

# Specialized script to upload TOP-LEVEL category pictograms (SVG).
# These are special icons for the main menu categories.

pictograms_dir = '/home/sushi/Documents/ikea_api/Пиктограммы верхних категорий'
supported_extensions = ['.svg', '.png']

unless Dir.exist?(pictograms_dir)
  puts "Error: Pictograms directory #{pictograms_dir} not found."
  exit 1
end

# Manual mapping for top-level categories where names differ slightly
TOP_LEVEL_MAPPING = {
  'Ванные комнаты' => 'Ванные комнаты',
  'Горшки и растения' => 'Горшки для цветов и растения',
  'Готовка и сервировка' => 'Приготовление еды и сервировка стола',
  'Декор' => 'Декоративные фигурки, статуэтки и украшения',
  'Дети и младенцы' => 'Товары для детей и новорожденных',
  'Диваны и кресла' => 'Диваны и кресла',
  'Домашние работы и ремонт' => 'Товары для ремонта и улучшения дома',
  'Домашняя электроника' => 'Электроника и бытовая техника для дома',
  'Еда и напитки' => 'Еда и напитки',
  'Кровати и матрасы' => 'Кровати и матрасы',
  'Кухни и кухонная техника' => 'Мебель и техника для кухни',
  'Мебель для хранения' => 'Мебель для хранения',
  'Мелкое хранение и организация' => 'Товары для организации хранения вещей',
  'Освещение' => 'Светильники и освещение',
  'Праздничная коллекция' => 'Праздничная коллекция',
  'Рабочие столы и кресла' => 'Рабочие столы и кресла',
  'Сад и балкон' => 'Товары для сада и балкона',
  'Стирка и уборка' => 'Стирка и уборка',
  'Столы и стулья' => 'Столы и стулья', # Might not be top level but exists
  'Текстиль и ковры' => 'Текстиль для спальни', # Closest match or generic textile
  'Товары для животных' => 'Товары для животных, зоотовары',
  'Умный дом' => 'Умный дом',
  'Шторы, занавески и жалюзи' => 'Шторы, гардины и жалюзи'
}

stats = { attached: 0, skipped: 0, errors: 0 }

puts "Processing top-level pictograms in #{pictograms_dir}..."

Dir.glob("#{pictograms_dir}/*.{svg,png}").each do |path|
  filename = File.basename(path, '.*').strip
  ext = File.extname(path).sub('.', '')
  
  # Get the target category name from mapping or use filename
  target_name = TOP_LEVEL_MAPPING[filename] || filename
  
  # Find top-level categories (no parents or is_important)
  category = Category.where('translated_name = ?', target_name).where(is_deleted: [false, nil]).first
  
  if category
    begin
      # Attach new pictogram (do not purge icon, we want both)
      category.pictogram.attach(
        io: File.open(path),
        filename: File.basename(path),
        content_type: "image/#{ext == 'svg' ? 'svg+xml' : ext}"
      )
      
      puts "Attached pictogram to ID #{category.ikea_id}: '#{category.translated_name}'"
      stats[:attached] += 1
    rescue => e
      puts "Error attaching pictogram to #{category.ikea_id}: #{e.message}"
      stats[:errors] += 1
    end
  else
    puts "No top-level category found for pictogram: '#{filename}' (Target: '#{target_name}')"
    stats[:skipped] += 1
  end
end

puts "\nTOP-LEVEL PICTOGRAMS UPLOAD COMPLETE:"
puts "---------------------------------------"
puts "Pictograms attached: #{stats[:attached]}"
puts "Pictograms skipped: #{stats[:skipped]}"
puts "Errors encountered: #{stats[:errors]}"
puts "---------------------------------------"
