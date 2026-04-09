# Полная переиндексация ProductFilterValue по всем категориям, у которых заданы available_filters.
#
# Запуск:
#   RAILS_ENV=production bundle exec rails runner scripts/reindex_category_filters.rb
#
# Опционально:
#   SKIP_CACHE_CLEAR=true   — не вызывать Rails.cache.clear в начале

skip_cache_clear = ENV['SKIP_CACHE_CLEAR'] == 'true'

unless skip_cache_clear
  puts "Очистка Rails.cache..."
  Rails.cache.clear rescue nil
end

scope = Category.all
total = scope.count
done = 0
errors = 0

puts "Категорий всего: #{total}"

scope.find_each do |category|
  next if Array(category.available_filters).blank?

  begin
    Products::FilterValuesIndexer.new(category).reindex!
    done += 1
    print "c" if (done % 10).zero?
  rescue StandardError => e
    errors += 1
    puts "\n[ERROR] ikea_id=#{category.ikea_id} id=#{category.id}: #{e.message}"
  end
end

puts "\nПереиндексировано категорий (с фильтрами): #{done}, ошибок: #{errors}"
puts "Готово!"
