class CreatePhoneVerificationRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :phone_verification_requests do |t|
      t.string :phone
      t.string :status
      t.text :error_message
      t.string :ip_address
      t.string :user_agent
      t.jsonb :metadata

      t.timestamps
    end
  end
end
