class CreateFavorites < ActiveRecord::Migration[7.1]
  def change
    create_table :favorites do |t|
      t.string :guest_token
      t.datetime :expires_at
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
    add_index :favorites, :guest_token
    add_index :favorites, :expires_at
  end
end
