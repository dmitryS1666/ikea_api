class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :username
      t.string :email
      t.string :password_digest
      t.string :role, default: 'user'
      t.boolean :is_active, default: true

      t.timestamps
    end
    add_index :users, :username, unique: true
  end
end
