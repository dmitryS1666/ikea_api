class CreatePickupPoints < ActiveRecord::Migration[7.1]
  def change
    create_table :pickup_points do |t|
      t.string :provider, null: false
      t.string :name, null: false
      t.string :city
      t.string :address
      t.string :phone
      t.string :working_hours
      t.decimal :lat, precision: 10, scale: 6
      t.decimal :lon, precision: 10, scale: 6
      t.boolean :priority, null: false, default: false
      t.boolean :active, null: false, default: true
      t.decimal :max_weight_kg, precision: 12, scale: 3
      t.decimal :max_volume_m3, precision: 12, scale: 6

      t.timestamps
    end

    add_index :pickup_points, [:provider, :active]
    add_index :pickup_points, [:priority, :active]
  end
end
