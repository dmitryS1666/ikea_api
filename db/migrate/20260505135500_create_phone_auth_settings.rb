class CreatePhoneAuthSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :phone_auth_settings do |t|
      t.boolean :asterisk_enabled, null: false, default: true

      t.timestamps
    end
  end
end
