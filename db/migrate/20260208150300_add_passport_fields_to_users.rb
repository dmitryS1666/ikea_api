class AddPassportFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :encrypted_passport_json, :text
    add_column :users, :passport_verified_at, :datetime
  end
end
