class NormalizeLegacyPickupDeliveryType < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE orders
      SET delivery_type = 'europost_pickup'
      WHERE delivery_type = 'pickup'
    SQL
  end

  def down
    # No-op: old delivery_type='pickup' is no longer supported by the application.
  end
end
