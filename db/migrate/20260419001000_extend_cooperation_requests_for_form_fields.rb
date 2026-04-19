class ExtendCooperationRequestsForFormFields < ActiveRecord::Migration[7.1]
  def change
    add_column :cooperation_requests, :first_name, :string
    add_column :cooperation_requests, :last_name, :string
    add_column :cooperation_requests, :cooperation_type, :string
    add_column :cooperation_requests, :comment, :text
    add_column :cooperation_requests, :personal_data_consent, :boolean, default: false, null: false
    add_column :cooperation_requests, :marketing_email_consent, :boolean, default: false, null: false

    add_index :cooperation_requests, :cooperation_type
  end
end

