# frozen_string_literal: true

class CreateWebpaySettings < ActiveRecord::Migration[7.1]
  def change
    create_table :webpay_settings do |t|
      # Safe default: sandbox until an admin explicitly enables production.
      t.boolean :test_mode, null: false, default: true

      t.timestamps
    end
  end
end
