class CreateCategories < ActiveRecord::Migration[7.1]
  def change
    create_table :categories do |t|
      t.string :ikea_id
      t.integer :unique_id
      t.string :name
      t.string :translated_name
      t.string :url
      t.string :remote_image_url
      t.string :local_image_path
      t.text :parent_ids
      t.boolean :is_deleted
      t.boolean :is_important
      t.boolean :is_popular

      t.timestamps
    end
    add_index :categories, :ikea_id, unique: true
  end
end
