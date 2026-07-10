class AddEmailVerifiedAtToUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :email_verified_at, :datetime

    execute <<~SQL.squish
      UPDATE users
      SET email_verified_at = COALESCE(updated_at, created_at, NOW())
      WHERE email IS NOT NULL
        AND BTRIM(email) <> ''
        AND (email_marketing IS TRUE OR newsletter_consent IS TRUE)
    SQL
  end

  def down
    remove_column :users, :email_verified_at
  end
end
