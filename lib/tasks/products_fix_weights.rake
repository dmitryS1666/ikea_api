# frozen_string_literal: true
# DRY_RUN=true LIMIT=50 bundle exec rake products:fix_suspicious_weights
# p = Product.find_by!(sku: "10331014")
# Products::WeightExtractor.extract_kg(p.full_attributes_ru)
# p.update!(weight: Products::WeightExtractor.extract_kg(p.full_attributes_ru))
# p.reload.weight
# 

def fallback_weight_from_product_text(product)
  text = [
    product.small_desc_name,
    product.name_ru
  ].compact.join(" ")

  extracted = Products::WeightExtractor.extract_kg_from_text(text)
  return nil if extracted.blank?

  old_weight = product.weight.to_f

  # Защита:
  # если в тексте 415 гр => extracted 0.415,
  # а в БД old_weight 415.0,
  # значит это точно граммы, записанные как кг.
  return extracted if old_weight > 100 && extracted < 10 && (old_weight / 1000.0 - extracted).abs <= 0.01

  nil
end

namespace :products do
  desc "Fix suspicious product weights using full_attributes_ru packaging data"
  task fix_suspicious_weights: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    force_all = ENV["FORCE_ALL"] == "true"
    limit = ENV["LIMIT"].presence&.to_i

    scope =
      if force_all
        Product.where.not(full_attributes_ru: [nil, {}])
      else
        Product.where("weight > ?", 100)
      end

    scope = scope.limit(limit) if limit.present? && limit.positive?

    total = scope.count
    fixed = 0
    skipped = 0
    errors = 0

    puts "Products weight fix"
    puts "DRY_RUN=#{dry_run}"
    puts "FORCE_ALL=#{force_all}"
    puts "TOTAL=#{total}"
    puts "-" * 80

    scope.find_each do |product|
      old_weight = product.weight.to_f
      new_weight =
        Products::WeightExtractor.extract_kg(product.full_attributes_ru) ||
        fallback_weight_from_product_text(product)
          
      if new_weight.blank?
        skipped += 1
        puts "SKIP sku=#{product.sku} old=#{product.weight.inspect} reason=no_valid_weight_source"
        next
      end
      
      if old_weight.round(3) == new_weight.to_f.round(3)
        skipped += 1
        puts "SKIP sku=#{product.sku} old=#{product.weight.inspect} new=#{new_weight} reason=same_weight"
        next
      end
      
      confirmed_packaging_bug =
        old_weight > 100 &&
        new_weight < 100 &&
        old_weight / new_weight > 10
      
      confirmed_text_grams_bug =
        old_weight > 100 &&
        new_weight < 10 &&
        (old_weight / 1000.0 - new_weight).abs <= 0.01
      
      unless confirmed_packaging_bug || confirmed_text_grams_bug
        skipped += 1
        puts "SKIP sku=#{product.sku} old=#{product.weight.inspect} new=#{new_weight} reason=not_confirmed_grams_bug"
        next
      end
      
      fixed += 1
      
      if dry_run
        puts "DRY sku=#{product.sku} old=#{product.weight.inspect} -> new=#{new_weight}"
      else
        product.update_columns(weight: new_weight, updated_at: Time.current)
        puts "FIX sku=#{product.sku} old=#{product.weight.inspect} -> new=#{new_weight}"
      end
    rescue => e
      errors += 1
      puts "ERROR sku=#{product.try(:sku)} #{e.class}: #{e.message}"
    end

    puts "-" * 80
    puts "DONE fixed=#{fixed} skipped=#{skipped} errors=#{errors}"
  end
end
