class FixSeoMetaSeoableIdType < ActiveRecord::Migration[7.1]
  def up
    change_column :seo_meta, :seoable_id, :string
  end

  def down
    change_column :seo_meta, :seoable_id, :bigint
  end
end
