class AddAvailableFiltersToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :available_filters, :jsonb, null: false, default: []
  end
end
