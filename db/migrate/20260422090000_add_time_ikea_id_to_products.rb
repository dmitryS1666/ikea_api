class AddTimeIkeaIdToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :time_ikea_id, :string
    add_index :products, :time_ikea_id
  end
end
