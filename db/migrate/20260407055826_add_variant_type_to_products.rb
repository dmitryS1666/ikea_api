class AddVariantTypeToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :variant_type, :string
  end
end
