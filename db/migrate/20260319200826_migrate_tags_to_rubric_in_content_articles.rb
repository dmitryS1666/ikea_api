class MigrateTagsToRubricInContentArticles < ActiveRecord::Migration[7.1]
  def up
    ContentArticle.reset_column_information
    ContentArticle.find_each do |article|
      if (article.rubric.nil? || article.rubric == "") && article.tags.is_a?(Array) && article.tags.present?
        article.update_column(:rubric, article.tags.first.to_s.strip)
      end
    end
  end

  def down
    # Оставляем рубрики, если миграция откатывается (структура БД остается прежней)
  end
end
