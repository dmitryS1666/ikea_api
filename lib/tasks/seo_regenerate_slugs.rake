# frozen_string_literal: true

namespace :seo do
  desc "Пересчитать cached_slug у товаров и категорий (после обновления SlugifyService)"
  task regenerate_slugs: :environment do
    updated_products = 0
    Product.find_each do |product|
      slug = product.send(:generate_slug)
      next if product.cached_slug == slug

      product.update_column(:cached_slug, slug)
      updated_products += 1
    end

    updated_categories = 0
    Category.find_each do |category|
      slug = category.send(:generate_slug)
      next if category.cached_slug == slug

      category.update_column(:cached_slug, slug)
      updated_categories += 1
    end

    Rails.cache.delete_matched("categories_tree_v2_*") if Rails.cache.respond_to?(:delete_matched)

    puts "Products updated: #{updated_products}"
    puts "Categories updated: #{updated_categories}"
  end
end
