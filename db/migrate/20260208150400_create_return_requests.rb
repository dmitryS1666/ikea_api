class CreateReturnRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :return_requests do |t|
      t.bigint :user_id, null: false
      t.bigint :order_id, null: false
      t.string :reason, null: false
      t.text :comment
      t.string :status, null: false, default: 'new'

      t.timestamps
    end

    add_index :return_requests, :user_id
    add_index :return_requests, :order_id
    add_index :return_requests, [:status, :created_at]
  end
end
