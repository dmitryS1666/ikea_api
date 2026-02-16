class RemoveFullAttributesRuFromProducts < ActiveRecord::Migration[7.1]
  def change
    remove_column :products, :full_attributes_ru, :jsonb
  end
end
