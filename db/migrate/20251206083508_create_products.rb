class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products do |t|
      t.string :sku
      t.integer :unique_id
      t.string :item_no
      t.string :url
      t.string :name
      t.string :name_ru
      t.string :collection
      t.text :variants
      t.text :related_products
      t.text :set_items
      t.text :bundle_items
      t.text :images
      t.text :local_images
      t.integer :images_total
      t.integer :images_stored
      t.boolean :images_incomplete
      t.text :videos
      t.text :manuals
      t.decimal :price
      t.integer :quantity
      t.string :home_delivery
      t.decimal :weight
      t.decimal :net_weight
      t.decimal :package_volume
      t.string :package_dimensions
      t.string :dimensions
      t.boolean :is_parcel
      t.text :content
      t.text :content_ru
      t.text :material_info
      t.text :material_info_ru
      t.text :good_info
      t.text :good_info_ru
      t.boolean :translated
      t.boolean :is_bestseller
      t.boolean :is_popular
      t.string :category_id
      t.string :delivery_type
      t.string :delivery_name
      t.decimal :delivery_cost
      t.string :delivery_reason

      t.timestamps
    end
    add_index :products, :sku, unique: true
  end
end
