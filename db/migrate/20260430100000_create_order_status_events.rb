class CreateOrderStatusEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :order_status_events do |t|
      t.references :order, null: false, foreign_key: true
      t.string :from_status
      t.string :to_status, null: false
      t.datetime :changed_at, null: false
      t.string :source, null: false, default: "system"
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :order_status_events, [:order_id, :changed_at]
    add_index :order_status_events, :to_status
  end
end
