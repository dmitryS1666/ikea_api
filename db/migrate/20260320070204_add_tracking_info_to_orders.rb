class AddTrackingInfoToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :tracking_info, :jsonb
  end
end
