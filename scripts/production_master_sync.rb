require 'json'

# MASTER synchronization script for Production/Local
# This script aligns the database with the final JSON structure.

json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'

unless File.exist?(json_path)
  puts "Error: Master JSON file not found at #{json_path}"
  exit 1
end

data = JSON.parse(File.read(json_path))
categories_tree = data['categories']

puts "Starting database synchronization..."
active_ids = Set.new
stats = { updated: 0, created: 0, deleted: 0 }

def sync_node(categories, parent_ids, active_ids, stats)
  categories.each do |cat|
    id = cat['ikea_id']
    name = cat['effective_name']
    
    if id
      active_ids.add(id)
      db_cat = Category.find_by(ikea_id: id)
      
      if db_cat
        db_cat.update!(
          translated_name: name,
          parent_ids: parent_ids,
          is_deleted: false
        )
        stats[:updated] += 1
      else
        Category.create!(
          ikea_id: id,
          translated_name: name,
          name: name, # fallback to translated if original name unknown
          parent_ids: parent_ids,
          is_deleted: false
        )
        stats[:created] += 1
      end
      
      # Recurse with current ID added to parents for children
      sync_node(cat['children'], parent_ids + [id], active_ids, stats) if cat['children']&.any?
    else
      # If node has no ID (spacer/folder), we still process children but keep the same parent_ids
      sync_node(cat['children'], parent_ids, active_ids, stats) if cat['children']&.any?
    end
  end
end

Category.transaction do
  sync_node(categories_tree, [], active_ids, stats)
  
  # Identify categories to delete
  to_delete_ids = Category.where.not(ikea_id: active_ids.to_a).pluck(:ikea_id)
  stats[:deleted] = to_delete_ids.size
  
  if to_delete_ids.any?
    puts "Cleaning up products associated with #{to_delete_ids.size} deleted categories..."
    
    # 1. Find products that are ONLY in categories being deleted
    # A product is a candidate if it's in at least one deleted category
    candidate_product_ids = Set.new
    candidate_product_ids += Product.where(category_id: to_delete_ids).pluck(:id)
    candidate_product_ids += CategoryProduct.where(category_id: to_delete_ids).pluck(:product_id)
    
    deleted_products_count = 0
    
    candidate_product_ids.to_a.each_slice(500) do |ids_batch|
      Product.where(id: ids_batch).find_each do |product|
        # Check if this product belongs to ANY active category
        has_active_old = product.category_id.present? && active_ids.include?(product.category_id)
        has_active_new = product.category_products.where(category_id: active_ids.to_a).exists?
        
        unless has_active_old || has_active_new
          # 1. Physical file cleanup (local_images)
          if product.respond_to?(:local_images) && product.local_images.is_a?(Array)
            product.local_images.each do |relative_path|
              full_path = Rails.root.join('public', relative_path.sub(/^\//, ''))
              File.delete(full_path) if File.exist?(full_path)
            end
          end

          # 2. Database record cleanup
          product.destroy
          deleted_products_count += 1
        end
      end
    end
    
    puts "Permanently deleted #{deleted_products_count} orphaned products."
    
    # 2. Finally delete the categories
    Category.where(ikea_id: to_delete_ids).destroy_all
  end
end

puts "\nSYNCHRONIZATION COMPLETE:"
puts "--------------------------"
puts "Categories updated: #{stats[:updated]}"
puts "Categories created: #{stats[:created]}"
puts "Categories PERMANENTLY deleted: #{stats[:deleted]}"
puts "Total active categories in DB: #{Category.count}"
puts "--------------------------"
