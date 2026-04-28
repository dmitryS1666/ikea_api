class CreateUserPickupPoints < ActiveRecord::Migration[7.1]
  def change
    create_table :user_pickup_points do |t|
      t.references :user, null: false, foreign_key: true
      t.references :pickup_point, null: true, foreign_key: true
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :city
      t.string :address
      t.string :working_hours
      t.decimal :lat, precision: 10, scale: 6
      t.decimal :lng, precision: 10, scale: 6
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :user_pickup_points,
              [:user_id, :provider, :external_id],
              unique: true,
              where: "deleted_at IS NULL",
              name: "idx_user_pickup_points_unique_active_provider_external"
  end
end
