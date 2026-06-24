# frozen_string_literal: true

class MakeOrdersUserIdOptional < ActiveRecord::Migration[7.1]
  def change
    change_column_null :orders, :user_id, true
  end
end
