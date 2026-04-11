# frozen_string_literal: true

namespace :category do
  desc "Статистика по категории ikea_id (пример: rake category:stats[700631])"
  task :stats, [:ikea_id] => :environment do |_t, args|
    ikea_id = (args[:ikea_id] || ENV["IKEA_CATEGORY_ID"]).to_s.strip
    if ikea_id.blank?
      puts "Укажите ikea_id: rake category:stats[700631] или IKEA_CATEGORY_ID=700631"
      exit 1
    end

    cat = Category.find_by(ikea_id: ikea_id)
    unless cat
      puts "Категория ikea_id=#{ikea_id.inspect} не найдена"
      exit 1
    end

    scope = Product.in_category_ikea_id(ikea_id)
    total = scope.count
    with_price = scope.where("COALESCE(price, 0) > 0").count
    in_stock = scope.where("COALESCE(quantity, 0) > 0").count
    with_remote_images = scope.where.not(images: [nil, "", "[]"]).count
    with_local_images = scope.where.not(local_images: [nil, "", "[]"]).count
    with_webp_local = scope.where("local_images ILIKE ?", "%.webp%").count
    with_assembly_docs = scope.where.not(assembly_documents: [nil, "", "[]"]).count
    bad_sku = scope.where("sku LIKE ? AND sku LIKE ?", '[%', '%"%').count

    puts "Категория: #{cat.name} (ikea_id=#{cat.ikea_id})"
    puts "Товаров в категории (основная category_id + category_products): #{total}"
    puts "С ценой > 0: #{with_price}"
    puts "С quantity > 0: #{in_stock}"
    puts "С непустым JSON images: #{with_remote_images}"
    puts "С непустым local_images JSON: #{with_local_images}"
    puts "С .webp в local_images: #{with_webp_local}"
    puts "С assembly_documents: #{with_assembly_docs}"
    puts "Битый sku (массив в строке): #{bad_sku}"
  end

  desc "Убрать все товары из категории: category_products + сброс products.category_id (rake category:clear_products[700631] или IKEA_CATEGORY_ID=700631)"
  task :clear_products, [:ikea_id] => :environment do |_t, args|
    ikea_id = (args[:ikea_id] || ENV["IKEA_CATEGORY_ID"]).to_s.strip
    if ikea_id.blank?
      puts "Укажите ikea_id: rake category:clear_products[700631] или IKEA_CATEGORY_ID=700631"
      exit 1
    end

    cat = Category.find_by(ikea_id: ikea_id)
    unless cat
      puts "Категория ikea_id=#{ikea_id.inspect} не найдена"
      exit 1
    end

    cid = cat.ikea_id.to_s
    cp_deleted = CategoryProduct.where(category_id: cid).delete_all
    product_ids = Product.where(category_id: cid).pluck(:id)
    Product.where(id: product_ids).find_each(batch_size: 200) do |product|
      fallback =
        CategoryProduct
          .where(product_id: product.id)
          .where.not(category_id: cid)
          .order(:category_id)
          .pick(:category_id)
      product.update_columns(category_id: fallback)
    end

    puts "Категория #{cid} (#{cat.name}): удалено связей category_products=#{cp_deleted}, сброшен/заменён category_id у товаров: #{product_ids.size}"
  end

  desc "Синхронно выполнить RefreshCategoryFromLtJob (IKEA_CATEGORY_ID=700631 rake category:refresh_lt)"
  task refresh_lt: :environment do
    ikea_id = ENV.fetch("IKEA_CATEGORY_ID") { abort("Задайте IKEA_CATEGORY_ID=700631") }
    max = ENV["MAX_CREATED"].presence&.to_i

    puts "RefreshCategoryFromLtJob.perform_now(ikea_id: #{ikea_id.inspect}, max_created: #{max.inspect})"
    RefreshCategoryFromLtJob.perform_now(ikea_id: ikea_id, max_created: max)
    puts "Готово. Задача в parser_tasks (последняя refresh_category_lt):"
    t = ParserTask.where(task_type: "refresh_category_lt").order(id: :desc).first
    if t
      puts "  id=#{t.id} status=#{t.status} processed=#{t.processed} created=#{t.created} updated=#{t.updated} errors=#{t.error_count}"
      puts "  payload=#{t.payload.inspect}" if t.payload.present?
      puts "  error=#{t.error_message.inspect}" if t.error_message.present?
    else
      puts "  (записей нет)"
    end
  end
end
