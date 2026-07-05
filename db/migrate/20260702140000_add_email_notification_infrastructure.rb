class AddEmailNotificationInfrastructure < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :abandoned_cart_email_sent_at, :datetime

    create_table :email_verification_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :email, null: false
      t.string :token, null: false
      t.string :purpose, null: false
      t.datetime :expires_at, null: false
      t.datetime :verified_at

      t.timestamps
    end

    add_index :email_verification_tokens, :token, unique: true
    add_index :email_verification_tokens, [:user_id, :purpose]
  end
end
