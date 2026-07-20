# frozen_string_literal: true

class AddEmailSuppressedAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :email_suppressed_at, :datetime
  end
end
