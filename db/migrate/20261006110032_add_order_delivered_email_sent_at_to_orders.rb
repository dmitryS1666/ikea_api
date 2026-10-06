# frozen_string_literal: true

class AddOrderDeliveredEmailSentAtToOrders < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:orders, :order_delivered_email_sent_at)
      add_column :orders, :order_delivered_email_sent_at, :datetime
    end

    unless index_exists?(:orders, :order_delivered_email_sent_at, name: "index_orders_on_pending_order_delivered_email")
      add_index :orders,
                :order_delivered_email_sent_at,
                where: "order_delivered_email_sent_at IS NULL",
                name: "index_orders_on_pending_order_delivered_email"
    end
  end

  def down
    if index_exists?(:orders, :order_delivered_email_sent_at, name: "index_orders_on_pending_order_delivered_email")
      remove_index :orders, name: "index_orders_on_pending_order_delivered_email"
    end

    remove_column :orders, :order_delivered_email_sent_at if column_exists?(:orders, :order_delivered_email_sent_at)
  end
end
