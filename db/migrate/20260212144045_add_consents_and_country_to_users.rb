class AddConsentsAndCountryToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :gdpr_consent, :boolean
    add_column :users, :newsletter_consent, :boolean
    add_column :users, :country_code, :string
  end
end
