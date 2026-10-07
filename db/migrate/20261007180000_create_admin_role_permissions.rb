# frozen_string_literal: true

class CreateAdminRolePermissions < ActiveRecord::Migration[7.1]
  def up
    create_table :admin_role_permissions do |t|
      t.string :role, null: false
      t.jsonb :permissions, null: false, default: {}
      t.timestamps
    end

    add_index :admin_role_permissions, :role, unique: true

    say_with_time "seed default role permissions" do
      User::ADMIN_PANEL_ROLES.each do |role|
        perms = User::BASE_ADMIN_PERMISSIONS.fetch(role, User::BASE_ADMIN_PERMISSIONS.fetch("user"))
        execute <<~SQL.squish
          INSERT INTO admin_role_permissions (role, permissions, created_at, updated_at)
          VALUES (
            #{connection.quote(role)},
            #{connection.quote(perms.to_json)}::jsonb,
            NOW(),
            NOW()
          )
          ON CONFLICT (role) DO NOTHING
        SQL
      end
    end
  end

  def down
    drop_table :admin_role_permissions
  end
end
