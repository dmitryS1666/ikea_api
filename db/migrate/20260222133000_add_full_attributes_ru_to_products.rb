class AddFullAttributesRuToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :full_attributes_ru, :jsonb, default: {}, null: false
  end
end
