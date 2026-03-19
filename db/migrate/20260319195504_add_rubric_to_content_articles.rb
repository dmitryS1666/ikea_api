class AddRubricToContentArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :content_articles, :rubric, :string
    add_index :content_articles, :rubric
  end
end
