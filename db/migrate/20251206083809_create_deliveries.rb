class CreateDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :deliveries do |t|
      t.decimal :weight
      t.string :delivery_type
      t.boolean :is_ikea_family
      t.decimal :order_value
      t.boolean :is_weekend

      t.timestamps
    end
  end
end
