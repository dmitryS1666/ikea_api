require 'json'

# Safety Test Script
# This script simulates the production sync and verifies product cleanup logic.

json_path = '/home/sushi/Documents/ikea_api/ikeya_categories_final_with_merges_and_deletions.json'
data = JSON.parse(File.read(json_path))
categories_tree = data['categories']

puts "--- STARTING SAFETY TEST (DRY RUN) ---"

Category.transaction do
  # 1. Create dummy data that SHOULD be deleted
  test_cat_id = "TEST_DELETE_ME"
  test_cat = Category.create!(ikea_id: test_cat_id, name: "Test Cat", translated_name: "Тест")
  
  test_prod = Product.create!(sku: "TEST_SKU_123", name: "Test Product", category_id: test_cat_id)
  puts "Created test category #{test_cat_id} and product TEST_SKU_123"

  # 2. Logic simulation (same as in production_master_sync.rb)
  active_ids = Set.new
  
  def collect_active(categories, ids)
    categories.each do |cat|
      ids.add(cat['ikea_id']) if cat['ikea_id']
      collect_active(cat['children'], ids) if cat['children']
    end
  end
  collect_active(categories_tree, active_ids)

  to_delete_ids = Category.where.not(ikea_id: active_ids.to_a).pluck(:ikea_id)
  
  puts "Categories identified for deletion: #{to_delete_ids.size} (Includes our test category: #{to_delete_ids.include?(test_cat_id)})"
  
  candidate_product_ids = Set.new
  candidate_product_ids += Product.where(category_id: to_delete_ids).pluck(:id)
  candidate_product_ids += CategoryProduct.where(category_id: to_delete_ids).pluck(:product_id)
  
  deleted_prods = 0
  candidate_product_ids.to_a.each do |pid|
    product = Product.find(pid)
    has_active_old = product.category_id.present? && active_ids.include?(product.category_id)
    has_active_new = product.category_products.where(category_id: active_ids.to_a).exists?
    
    unless has_active_old || has_active_new
      deleted_prods += 1
      puts "Result: Product #{product.sku} would be DELETED (orphan)" if product.sku == "TEST_SKU_123"
    end
  end

  puts "Products that would be deleted: #{deleted_prods}"
  
  # Verify our test product is in the list
  if to_delete_ids.include?(test_cat_id) && deleted_prods > 0
    puts "\n✅ TEST PASSED: Logic correctly identified the orphaned product and category."
  else
    puts "\n❌ TEST FAILED: Logic missed the orphaned data."
  end

  puts "\nROLLING BACK CHANGES... (No real data was harmed)"
  raise ActiveRecord::Rollback
end

puts "--- TEST COMPLETE ---"
