class AddIsNewToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :is_new, :boolean
  end
end
