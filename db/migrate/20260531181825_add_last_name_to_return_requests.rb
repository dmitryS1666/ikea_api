class AddLastNameToReturnRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :return_requests, :last_name, :string
  end
end
