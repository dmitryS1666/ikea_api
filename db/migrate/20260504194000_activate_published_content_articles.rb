class ActivatePublishedContentArticles < ActiveRecord::Migration[7.1]
  def up
    execute "UPDATE content_articles SET active = TRUE WHERE status = 1"
  end

  def down
    # No-op: this data migration restores visibility for already published articles.
  end
end
