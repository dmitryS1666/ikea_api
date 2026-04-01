class AddRootPositionToCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :root_position, :integer
  end
end
