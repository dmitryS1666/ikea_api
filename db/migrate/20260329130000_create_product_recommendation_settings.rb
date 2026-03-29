class CreateProductRecommendationSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :product_recommendation_settings do |t|
      t.integer :placement, null: false
      t.integer :source_type, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.string :category_id
      t.jsonb :product_skus, null: false, default: []

      t.timestamps
    end

    add_index :product_recommendation_settings, :placement, unique: true
    add_index :product_recommendation_settings, :active
    add_index :product_recommendation_settings, :product_skus, using: :gin
  end
end
