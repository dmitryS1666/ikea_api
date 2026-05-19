class AddGuestFieldsToReturnRequests < ActiveRecord::Migration[7.1]
  def change
    change_column_null :return_requests, :user_id, true

    add_column :return_requests, :first_name, :string
    add_column :return_requests, :patronymic, :string
    add_column :return_requests, :order_number, :string
    add_column :return_requests, :phone, :string
    add_column :return_requests, :email, :string
    add_column :return_requests, :compensation_type, :string

    add_index :return_requests, :order_number
  end
end
