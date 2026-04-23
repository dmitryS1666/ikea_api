class AddMissingRelatedSkusToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :missing_related_skus, :text
  end
end
