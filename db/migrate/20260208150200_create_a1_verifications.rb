class CreateA1Verifications < ActiveRecord::Migration[7.1]
  def change
    create_table :a1_verifications do |t|
      t.bigint :user_id
      t.string :phone, null: false
      t.string :context, null: false
      t.string :status, null: false, default: 'pending'
      t.string :expected_last4, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :a1_verifications, :user_id
    add_index :a1_verifications, [:phone, :status]
  end
end
