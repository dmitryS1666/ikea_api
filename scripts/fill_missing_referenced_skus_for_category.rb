#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "set"

target_ikea_id = (ARGV[0] || ENV["IKEA_CATEGORY_ID"] || "700631").to_s.strip
dry_run = ENV.fetch("DRY_RUN", "1") != "0"
max_skus = ENV["MAX_SKUS"].presence&.to_i

abort("IKEA_CATEGORY_ID is blank") if target_ikea_id.blank?

target_category = Category.find_by(ikea_id: target_ikea_id)
abort("Category #{target_ikea_id} not found") unless target_category

allowed_category_ids = Set.new([target_ikea_id] + target_category.descendant_ikea_ids.map(&:to_s))

def normalize_ref(raw)
  s = raw.to_s.gsub(/[^0-9a-z]/i, "").downcase
  return nil if s.blank?
  return s if s.match?(/\A\d{8}\z/) || s.match?(/\As\d{8}\z/)

  nil
end

def listing_related_refs_for_category(category_ikea_id)
  refs = Set.new
  Product.in_category_ikea_id(category_ikea_id).find_each(batch_size: 200) do |p|
    values = []
    values.concat Array(p.related_products)
    values.concat Array(p.included_products)
    values.concat Array(p.set_items)
    values.concat p.normalized_variant_skus
    values.each do |value|
      normalized = normalize_ref(value)
      refs << normalized if normalized.present?
    end
  end
  refs
end

def ensure_product_and_enrich!(sku, dry_run:)
  product = Products::ListingSkuResolver.find_product(sku)
  created = false

  unless product
    return [nil, false] if dry_run

    article = sku.to_s.match(/(\d{8})/)&.captures&.first
    product = Product.create!(
      sku: sku,
      item_no: article,
      name: "IKEA #{sku}",
      price: 0,
      quantity: 0,
      url: "https://www.ikea.com/pl/pl/p/-#{article || sku}/"
    )
    created = true
  end

  return [product, created] if dry_run

  Products::ExtendedAttributesFetchService.fetch_for_product(
    product,
    force_ai_translation: false,
    fallback_pl_when_lt_missing: true
  )
  product.reload
  [product, created]
end

all_refs = listing_related_refs_for_category(target_ikea_id)
missing = all_refs.reject { |sku| Products::ListingSkuResolver.find_product(sku).present? }.to_a
missing = missing.first(max_skus) if max_skus.present? && max_skus.positive?

puts "=" * 100
puts "Fill missing referenced SKUs for category=#{target_ikea_id} (#{target_category.name})"
puts "Dry run: #{dry_run}"
puts "Allowed detected category ids: target + descendants => #{allowed_category_ids.size}"
puts "Missing referenced SKUs: #{missing.size}"
puts "=" * 100

stats = {
  processed: 0,
  created: 0,
  enriched: 0,
  detected: 0,
  linked_to_target: 0,
  linked_to_detected: 0,
  unresolved_category: 0,
  out_of_scope_category: 0,
  errors: 0
}

missing.each do |sku|
  begin
    product, created = ensure_product_and_enrich!(sku, dry_run: dry_run)
    if product.nil?
      puts "[WARN] sku=#{sku} action=skip (dry-run and no product in DB)"
      stats[:processed] += 1
      next
    end
    stats[:created] += 1 if created
    stats[:enriched] += 1

    detected = Products::IkeaCategoryProbeService.detect(product)&.to_s
    if detected.present?
      stats[:detected] += 1
      product.update!(time_ikea_id: detected) unless dry_run
    end

    if detected.present? && allowed_category_ids.include?(detected)
      unless dry_run
        CategoryProduct.find_or_create_by!(product: product, category_id: target_ikea_id)
        if Category.find_by(ikea_id: detected)
          CategoryProduct.find_or_create_by!(product: product, category_id: detected)
        end
      end
      stats[:linked_to_target] += 1
      stats[:linked_to_detected] += 1 if detected != target_ikea_id
      puts "[OK] sku=#{sku} detected=#{detected} action=link_target#{detected != target_ikea_id ? '+detected' : ''}"
    elsif detected.blank?
      stats[:unresolved_category] += 1
      puts "[WARN] sku=#{sku} detected=nil action=skip_link (need manual or retry)"
    else
      stats[:out_of_scope_category] += 1
      puts "[WARN] sku=#{sku} detected=#{detected} action=skip_link (outside target subtree)"
    end

    stats[:processed] += 1
  rescue StandardError => e
    stats[:errors] += 1
    puts "[ERROR] sku=#{sku} #{e.class}: #{e.message}"
  end
end

puts "-" * 100
stats.each { |k, v| puts "#{k}: #{v}" }
puts "=" * 100
