class AddAvailableFiltersRuToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :available_filters_ru, :jsonb
  end
end
