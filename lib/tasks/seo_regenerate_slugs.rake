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

    if Rails.cache.respond_to?(:delete_matched)
      begin
        %w[
          categories_tree_v1
          categories_tree_v2_*
          categories_map_json_v2
          categories_map_json_v3_*
          category_show_v1_*
        ].each { |pattern| Rails.cache.delete_matched(pattern) }
        puts "Category caches invalidated."
      rescue Redis::CommandError, RedisClient::CommandError => e
        warn "Category caches not invalidated (#{e.class}: #{e.message}). Slug updates are saved."
      end
    end

    puts "Products updated: #{updated_products}"
    puts "Categories updated: #{updated_categories}"
  end
end
