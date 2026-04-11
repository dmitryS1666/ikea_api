# frozen_string_literal: true

namespace :products do
  desc <<-DESC.squish
    Товары с польскими буквами в short_description: список категорий (по связям),
    затем short_description и short_description_ru = small_desc_name,
    в full_attributes ключ short_description синхронизируется или удаляется.
    DRY_RUN=1 — только отчёт, без обновления.
  DESC
  task fix_short_description_polish_with_small_desc: :environment do
    pl_pattern = "[ąćęłńóśźż]"
    dry_run = %w[1 true yes].include?(ENV.fetch("DRY_RUN", "").to_s.downcase)

    scope = Product.where("short_description ~* ?", pl_pattern)
    total = scope.count
    puts "Товаров с польскими буквами в short_description: #{total}"
    if total.zero?
      puts "Нечего делать."
      next
    end

    category_hits = Hash.new(0)
    scope.includes(:category, :categories).find_each do |product|
      names = product.categories.map(&:name)
      names << product.category&.name
      names.compact.uniq.each { |n| category_hits[n] += 1 }
    end

    puts "\nКатегории (число вхождений: один товар может дать несколько, если в нескольких категориях):"
    category_hits.sort_by { |_, c| -c }.each do |name, cnt|
      puts "  #{cnt}\t#{name}"
    end

    if dry_run
      puts "\nDRY_RUN=1 — обновление пропущено. Уберите DRY_RUN для записи в БД."
      next
    end

    has_ru = Product.column_names.include?("short_description_ru")
    updated = 0
    errors = 0

    scope.find_each do |product|
      new_val = product.small_desc_name.to_s.strip.presence
      fa = product.full_attributes.is_a?(Hash) ? product.full_attributes.deep_stringify_keys.dup : {}
      if new_val.present?
        fa["short_description"] = new_val
      else
        fa.delete("short_description")
      end

      attrs = {
        short_description: new_val,
        full_attributes: fa
      }
      attrs[:short_description_ru] = new_val if has_ru

      product.update!(attrs)
      updated += 1
    rescue StandardError => e
      errors += 1
      warn "SKU #{product.sku}: #{e.message}"
    end

    puts "\nОбновлено товаров: #{updated}, ошибок: #{errors}"
  end
end
