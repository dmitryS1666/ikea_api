class CreatePolandTrackExports < ActiveRecord::Migration[7.1]
  def change
    add_column :order_items, :poland_price_pln, :decimal, precision: 12, scale: 2
    add_column :order_items, :poland_product_url, :text

    create_table :poland_track_exports do |t|
      t.references :order, null: false, foreign_key: true, index: { unique: true }
      t.string :state, null: false, default: "pending"
      t.text :payload_json
      t.jsonb :remote_response, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :next_attempt_at
      t.datetime :last_attempt_at
      t.timestamps
    end
    add_index :poland_track_exports, [:state, :next_attempt_at]
  end
end
