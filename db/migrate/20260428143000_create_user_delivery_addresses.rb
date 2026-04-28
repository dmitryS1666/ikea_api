class CreateUserDeliveryAddresses < ActiveRecord::Migration[7.1]
  def change
    create_table :user_delivery_addresses do |t|
      t.references :user, null: false, foreign_key: true
      t.string :city
      t.string :street
      t.string :house
      t.string :building
      t.string :apartment
      t.string :entrance
      t.string :floor
      t.boolean :has_elevator
      t.string :intercom
      t.boolean :is_private_house, null: false, default: false
      t.decimal :lat, precision: 10, scale: 6
      t.decimal :lng, precision: 10, scale: 6
      t.text :comment
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :user_delivery_addresses, [:user_id, :deleted_at]
  end
end
