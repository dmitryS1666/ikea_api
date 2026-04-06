class AddA1VerificationIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :a1_verification_id, :string
  end
end
