# frozen_string_literal: true

class AddPopularPositionToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :popular_position, :integer, default: 0, null: false
    add_index :categories, :popular_position
  end
end
