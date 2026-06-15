class ReplaceHasElevatorWithElevatorType < ActiveRecord::Migration[7.1]
  def up
    add_column :user_delivery_addresses, :elevator_type, :string

    execute <<~SQL.squish
      UPDATE user_delivery_addresses
      SET elevator_type = 'passenger'
      WHERE has_elevator = TRUE
    SQL

    remove_column :user_delivery_addresses, :has_elevator
  end

  def down
    add_column :user_delivery_addresses, :has_elevator, :boolean

    execute <<~SQL.squish
      UPDATE user_delivery_addresses
      SET has_elevator = TRUE
      WHERE elevator_type IS NOT NULL
    SQL

    remove_column :user_delivery_addresses, :elevator_type
  end
end
