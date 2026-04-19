class AddWebpayTransactionFieldsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :webpay_transaction_id, :string
    add_column :orders, :webpay_paid_at, :datetime

    add_index :orders, :webpay_transaction_id, unique: true, where: "webpay_transaction_id IS NOT NULL"
  end
end
