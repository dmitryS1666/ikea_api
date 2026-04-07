class AddPaymentExpirationToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :payment_expires_at, :datetime
    add_column :orders, :payment_url, :string
  end
end
