# frozen_string_literal: true

class AddOrderEmailQueue < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :pending_order_email_keys, :jsonb, null: false, default: []
    add_column :orders, :email_dispatch_locked_at, :datetime
  end
end
