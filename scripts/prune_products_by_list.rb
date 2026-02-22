require 'json'
require 'set'

list_path = ARGV[0] || Rails.root.join('scripts', 'products_input_extended_attrs_20260213_071029.json').to_s
keep_limit = (ARGV[1] || 100).to_i

unless File.exist?(list_path)
  puts "List file not found: #{list_path}"
  exit 1
end

data = JSON.parse(File.read(list_path))
products = Array(data['products'])
keep_skus = products.first(keep_limit).map { |p| p['sku'].to_s.strip }.reject(&:empty?).uniq

if keep_skus.empty?
  puts 'No SKUs found in list. Abort.'
  exit 1
end

def parse_local_images(raw)
  return [] if raw.blank?

  if raw.is_a?(String)
    begin
      parsed = JSON.parse(raw)
      return Array(parsed).compact
    rescue JSON::ParserError
      return [raw].compact
    end
  end

  Array(raw).compact
end

keep_images = Set.new
Product.where(sku: keep_skus).select(:id, :local_images).find_each do |product|
  parse_local_images(product.local_images).each { |path| keep_images.add(path) }
end

delete_images = Set.new
Product.where.not(sku: keep_skus).select(:id, :local_images).find_each do |product|
  parse_local_images(product.local_images).each { |path| delete_images.add(path) }
end

delete_images.subtract(keep_images)

storage = ImageDownloader.storage
if delete_images.any?
  puts "Deleting #{delete_images.size} product images..."
  delete_images.each do |path|
    next if path.blank?
    next if storage == ImageStorage::Local && path.to_s.start_with?('http')

    begin
      storage.delete(path)
    rescue NotImplementedError
      puts 'Storage delete not implemented. Skipping image cleanup.'
      break
    rescue => e
      puts "Failed to delete image #{path}: #{e.message}"
    end
  end
end

unless Object.const_defined?('HomepageProductBlockItem')
  class HomepageProductBlockItem < ApplicationRecord
    self.table_name = 'homepage_product_block_items'
  end
end

total = Product.where.not(sku: keep_skus).count
puts "Deleting #{total} products..."

Product.where.not(sku: keep_skus).find_in_batches(batch_size: 500) do |batch|
  ids = batch.map(&:id)
  skus = batch.map(&:sku)

  SeoMetum.where(seoable_type: 'Product', seoable_id: ids).delete_all
  CategoryProduct.where(product_id: ids).delete_all
  ProductFilterValue.where(product_id: ids).delete_all
  HomepageProductBlockItem.where(product_id: skus).delete_all

  Product.where(id: ids).delete_all
end

puts "Done. Kept #{keep_skus.size} products and all categories."
