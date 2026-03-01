class AddDetailedProfileFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :first_name, :string
    add_column :users, :last_name, :string
    add_column :users, :middle_name, :string
    add_column :users, :region, :string
    add_column :users, :city, :string
    add_column :users, :postcode, :string
    add_column :users, :street, :string
    add_column :users, :house, :string
    add_column :users, :building, :string
    add_column :users, :apartment, :string
  end
end
