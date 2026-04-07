class AddVariantsPayloadToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :variants_payload, :text
  end
end
