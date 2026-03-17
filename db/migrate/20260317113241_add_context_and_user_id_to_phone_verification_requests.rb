class AddContextAndUserIdToPhoneVerificationRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :phone_verification_requests, :context, :string
    add_column :phone_verification_requests, :user_id, :bigint
  end
end
