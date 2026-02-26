class AddIsRecommendedToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :is_recommended, :boolean
  end
end
