class CreateSeoMeta < ActiveRecord::Migration[7.1]
  def change
    create_table :seo_meta do |t|
      t.references :seoable, polymorphic: true, null: false
      t.string :title
      t.text :description
      t.string :keywords
      t.string :robots
      t.text :seo_text

      t.timestamps
    end
  end
end
