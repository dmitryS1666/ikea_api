class AddCodeToPhoneVerificationRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :phone_verification_requests, :code, :string
  end
end
