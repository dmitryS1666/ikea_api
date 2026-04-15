class AddAmoCrmFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :crm_contact_id, :string
    add_index :users, :crm_contact_id
  end
end
