class AddSmallDescNameToProducts < ActiveRecord::Migration[7.0]
  def change
    add_column :products, :small_desc_name, :text
  end
end
