# frozen_string_literal: true

# Ссылки на категории в статьях/новостях не хранятся в body_blocks — только button_category_id.
# URL собирается при отдаче API (ContentArticle#serialized_body_blocks → Category#catalog_url).
# После деплоя фикса catalog_url опубликованные материалы получают правильные /catalog/.../ автоматически.
#
# Эта миграция гарантирует cached_slug у категорий, на которые ссылаются статьи (и их предков),
# иначе catalog_url может вернуть nil.
class BackfillCategorySlugsForContentArticles < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    category_ids = category_ids_from_content_articles
    return if category_ids.empty?

    categories = Category.where(ikea_id: category_ids).to_a
    return if categories.empty?

    ancestor_ids = categories.flat_map { |category| Category.normalize_parent_ids(category.parent_ids) }
    all_categories = Category.where(ikea_id: (category_ids + ancestor_ids).uniq).to_a

    all_categories.each do |category|
      slug = category.slug.to_s.presence
      next if slug.blank?
      next if category.cached_slug == slug

      category.update_column(:cached_slug, slug)
    end
  end

  def down
    # Данные slug не откатываем — они нужны каталогу независимо от статей.
  end

  private

  def category_ids_from_content_articles
    ids = []

    ContentArticle.find_each do |article|
      Array.wrap(article.body_blocks).each do |block|
        ids << block["button_category_id"] if block["button_category_id"].present?
        ids << block["slider_category_id"] if block["slider_category_id"].present?
        ids.concat(Array.wrap(block["grid_category_ids"]).compact)
      end
    end

    ids.map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end
end
