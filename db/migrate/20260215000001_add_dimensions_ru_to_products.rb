class AddDimensionsRuToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :dimensions_ru, :text
  end
end
