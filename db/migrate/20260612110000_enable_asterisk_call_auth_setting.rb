# frozen_string_literal: true

class EnableAsteriskCallAuthSetting < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:phone_auth_settings)

    if select_value("SELECT COUNT(*) FROM phone_auth_settings").to_i.zero?
      execute <<~SQL.squish
        INSERT INTO phone_auth_settings (asterisk_enabled, created_at, updated_at)
        VALUES (TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    else
      execute <<~SQL.squish
        UPDATE phone_auth_settings
        SET asterisk_enabled = TRUE,
            updated_at = CURRENT_TIMESTAMP
      SQL
    end
  end

  def down
    return unless table_exists?(:phone_auth_settings)

    execute <<~SQL.squish
      UPDATE phone_auth_settings
      SET asterisk_enabled = FALSE,
          updated_at = CURRENT_TIMESTAMP
    SQL
  end
end
