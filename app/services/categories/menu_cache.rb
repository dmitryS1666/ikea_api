# frozen_string_literal: true

module Categories
  # Долгоживущий кеш стабильного меню каталога (структура категорий почти не меняется).
  # Сбрасывается вместе с tree при изменениях в admin / hierarchy import.
  module MenuCache
    TOP_KEY = "categories_top_v1"
    POPULAR_KEY = "categories_popular_v1"
    TTL = 7.days
    TREE_TTL = 7.days

    module_function

    def bust!
      Rails.cache.delete(TOP_KEY)
      Rails.cache.delete(POPULAR_KEY)
      Rails.cache.delete_matched("categories_tree_*") if Rails.cache.respond_to?(:delete_matched)
    rescue StandardError => e
      Rails.logger.warn("[Categories::MenuCache] bust failed: #{e.class} #{e.message}")
    end
  end
end
