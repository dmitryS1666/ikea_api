# Скрипт для безопасного удаления товаров без картинок
# Запуск:
#   bundle exec rails runner scripts/safe_delete_empty_products.rb
#   DRY_RUN=false bundle exec rails runner scripts/safe_delete_empty_products.rb
# Опционально:
#   DELETE_INTERNAL_LINKED=true  # удалять SKU, на которые ссылаются только SKU из этого же списка
#   FORCE_UNLINK=true            # удалить SKU из связей у других товаров, затем удалить сами SKU
#   SKIP_REINDEX=true            # не вызывать Products::FilterValuesIndexer и не чистить Rails.cache

file_path = 'app/empty_skus_img.txt'
unless File.exist?(file_path)
  puts "Файл #{file_path} не найден!"
  exit
end

# Режим тестового прогона (по умолчанию true, если не указано обратное)
dry_run = ENV['DRY_RUN'] != 'false'
delete_internal_linked = ENV['DELETE_INTERNAL_LINKED'] == 'true'
force_unlink = ENV['FORCE_UNLINK'] == 'true'
skip_reindex = ENV['SKIP_REINDEX'] == 'true'

if dry_run
  puts "!!! ВНИМАНИЕ: ЗАПУЩЕН ТЕСТОВЫЙ ПРОГОН (DRY_RUN) !!!"
  puts "Никакие данные не будут удалены. Для реального удаления запустите с DRY_RUN=false\n"
else
  puts "!!! ВНИМАНИЕ: ЗАПУЩЕНО РЕАЛЬНОЕ УДАЛЕНИЕ !!!\n"
end
puts "Режим DELETE_INTERNAL_LINKED: #{delete_internal_linked ? 'ON' : 'OFF'}"
puts "Режим FORCE_UNLINK: #{force_unlink ? 'ON' : 'OFF'}"
puts "Режим SKIP_REINDEX: #{skip_reindex ? 'ON' : 'OFF'}"

# 1. Загружаем SKU из файла
empty_skus = File.readlines(file_path).map do |line|
  # Поддержка форматов: 
  # 1. "643|40177228 | ..." (с разделителем |)
  # 2. "40177228" (просто SKU на строке)
  if line.include?('|')
    parts = line.split('|')
    sku_part = parts[1] || parts[0] # Если формат N|SKU, берем вторую часть
    sku_part.strip if sku_part
  else
    line.strip
  end
end.compact.reject(&:empty?).uniq

puts "--- Анализ удаления #{empty_skus.size} SKU ---"

stats = {
  total: empty_skus.size,
  not_found: 0,
  protected_external_links: 0,
  internal_only_links: 0,
  unlinked: 0,
  to_delete: 0,
  deleted: 0,
  errors: 0,
  affected_categories: Set.new,
  sample_to_delete: [],
  sample_protected: [],
  sample_internal_only: [],
  unlinked_refs_products: 0,
  unlinked_refs_entries: 0
}

# Карта ссылок: target_sku => [{from_sku:, from_name:, field:}, ...]
puts "Сканируем базу на наличие связей (это может занять время)..."
links_map = Hash.new { |h, k| h[k] = [] }
Product.find_each do |p|
  [
    [:variants, p.variants],
    [:related_products, p.related_products],
    [:set_items, p.set_items],
    [:bundle_items, p.bundle_items],
    [:included_products, p.included_products]
  ].each do |field_name, field|
    next if field.blank?

    Array(field).each do |item|
      sku = item.is_a?(Hash) ? (item['sku'] || item[:sku]) : item
      next if sku.blank?

      links_map[sku.to_s] << {
        from_sku: p.sku.to_s,
        from_name: p.name.to_s,
        field: field_name.to_s
      }
    end
  end
end

puts "Найдено всего уникальных SKU в связях: #{links_map.keys.size}"
empty_skus_set = empty_skus.to_set

def normalize_linked_sku(item)
  if item.is_a?(Hash)
    (item['sku'] || item[:sku] || item['item_no'] || item[:item_no]).to_s.strip
  else
    item.to_s.strip
  end
end

def remove_skus_from_field(field_value, target_skus_set)
  original = Array(field_value)
  filtered = original.reject do |item|
    sku = normalize_linked_sku(item)
    sku.present? && target_skus_set.include?(sku)
  end
  [filtered, original.size - filtered.size]
end

# 2. Если нужно - сначала очищаем ссылки у других товаров (варианты/похожие/включенные)
if force_unlink
  puts "\nFORCE_UNLINK: удаляем ссылки на SKU из fields у других товаров..."
  Product.find_each do |product|
    updates = {}
    removed_count = 0

    {
      variants: product.variants,
      related_products: product.related_products,
      included_products: product.included_products,
      set_items: product.set_items,
      bundle_items: product.bundle_items
    }.each do |field_name, field_value|
      next if field_value.blank?

      filtered, removed = remove_skus_from_field(field_value, empty_skus_set)
      next if removed.zero?

      updates[field_name] = filtered
      removed_count += removed
    end

    next if updates.empty?

    stats[:unlinked_refs_products] += 1
    stats[:unlinked_refs_entries] += removed_count

    if dry_run
      if stats[:sample_protected].size < 10
        stats[:sample_protected] << "UNLINK #{product.sku}: -#{removed_count} ссылок"
      end
    else
      begin
        product.update_columns(updates)
      rescue StandardError => e
        stats[:errors] += 1
        puts "\n[ERROR] Ошибка unlink для SKU #{product.sku}: #{e.message}"
      end
    end
  end
end

# 3. Основной цикл удаления
empty_skus.each do |sku|
  product = Product.find_by(sku: sku)

  unless product
    stats[:not_found] += 1
    next
  end

  referrers = if force_unlink
                []
              else
                Array(links_map[sku.to_s]).reject { |r| r[:from_sku].to_s == sku.to_s }
              end
  has_links = referrers.any?
  has_external_links = referrers.any? { |r| !empty_skus_set.include?(r[:from_sku].to_s) }

  if !has_links
    stats[:unlinked] += 1
  elsif has_external_links
    stats[:protected_external_links] += 1
    if stats[:sample_protected].size < 10
      sample = referrers.first
      stats[:sample_protected] << "#{sku} <= #{sample[:from_sku]} (#{sample[:from_name]}) via #{sample[:field]}"
    end
    next
  else
    stats[:internal_only_links] += 1
    if stats[:sample_internal_only].size < 10
      sample = referrers.first
      stats[:sample_internal_only] << "#{sku} <= #{sample[:from_sku]} via #{sample[:field]}"
    end
    next unless delete_internal_linked
  end

  # Собираем категории для последующей переиндексации
  cat_ids = product.categories.pluck(:ikea_id)
  cat_ids << product.category_id if product.category_id.present?
  cat_ids.compact.uniq.each { |id| stats[:affected_categories] << id }

  if dry_run
    stats[:to_delete] += 1
    stats[:sample_to_delete] << "#{sku} (#{product.name})" if stats[:sample_to_delete].size < 10
  else
    begin
      product.destroy
      stats[:deleted] += 1
      print "." if (stats[:deleted] % 50) == 0
    rescue => e
      stats[:errors] += 1
      puts "\n[ERROR] Ошибка при удалении SKU #{sku}: #{e.message}"
    end
  end
end

puts "\n\n--- Результаты ---"
puts "Всего в списке:    #{stats[:total]}"
puts "Не найдено в БД:   #{stats[:not_found]}"
puts "Без ссылок:        #{stats[:unlinked]}"
puts "Связи только внутри списка: #{stats[:internal_only_links]}"
puts "Защищены внешними ссылками: #{stats[:protected_external_links]} (пропущены для безопасности)"
puts "Очищено ссылок (products): #{stats[:unlinked_refs_products]}"
puts "Очищено ссылок (entries):  #{stats[:unlinked_refs_entries]}"

if dry_run
  puts "Будет удалено:     #{stats[:to_delete]}"
  puts "\nПримеры товаров к удалению:"
  stats[:sample_to_delete].each { |s| puts " - #{s}" }
else
  puts "Удалено успешно:   #{stats[:deleted]}"
  puts "Ошибок удаления:   #{stats[:errors]}"
end

if stats[:sample_protected].any?
  puts "\nПримеры защищенных SKU (есть внешние ссылки):"
  stats[:sample_protected].each { |s| puts " - #{s}" }
end

if stats[:sample_internal_only].any?
  puts "\nПримеры SKU со связями только внутри списка:"
  stats[:sample_internal_only].each { |s| puts " - #{s}" }
end

puts "Будет затронуто категорий: #{stats[:affected_categories].size}"

# 4. Переиндексация фильтров (можно отложить: SKIP_REINDEX=true)
if skip_reindex
  if stats[:affected_categories].any?
    puts "\n[SKIP_REINDEX] Переиндексацию не запускали. Категорий к переиндексации позже: #{stats[:affected_categories].size}"
    puts "Когда будете готовы: DRY_RUN=false SKIP_REINDEX=false (или без SKIP_REINDEX) — либо отдельный rake/скрипт по ikea_id категорий."
  end
elsif !dry_run && stats[:deleted] > 0 && stats[:affected_categories].any?
  puts "\nЗапуск переиндексации фильтров для #{stats[:affected_categories].size} категорий..."

  Rails.cache.clear rescue nil

  stats[:affected_categories].each do |ikea_id|
    category = Category.find_by(ikea_id: ikea_id)
    next unless category

    begin
      Products::FilterValuesIndexer.new(category).reindex!
      print "c"
    rescue => e
      puts "\n[ERROR] Ошибка переиндексации категории #{ikea_id}: #{e.message}"
    end
  end
  puts "\nПереиндексация завершена."
elsif dry_run && stats[:affected_categories].any?
  puts "\n[DRY_RUN] После реального удаления будет переиндексировано #{stats[:affected_categories].size} категорий (если не задан SKIP_REINDEX=true)."
end

puts "\nГотово!"

