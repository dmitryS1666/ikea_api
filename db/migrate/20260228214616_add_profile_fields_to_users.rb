class AddProfileFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :dob, :date
    add_column :users, :gender, :string
    add_column :users, :address, :text
    add_column :users, :telegram_marketing, :boolean
    add_column :users, :email_marketing, :boolean
  end
end
