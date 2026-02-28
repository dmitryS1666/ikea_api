class CreatePromoCodeCategories < ActiveRecord::Migration[7.1]
  def change
    create_table :promo_code_categories do |t|
      t.references :promo_code, null: false, foreign_key: true
      t.string :category_id, null: false

      t.timestamps
    end
    add_index :promo_code_categories, [:promo_code_id, :category_id], unique: true
  end
end
