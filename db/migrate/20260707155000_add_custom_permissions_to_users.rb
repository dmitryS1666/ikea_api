class AddCustomPermissionsToUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :custom_permissions, :jsonb, default: {}, null: false

    execute <<~SQL
      UPDATE users
      SET role = 'manager_requests'
      WHERE role = 'manager';
    SQL
  end

  def down
    execute <<~SQL
      UPDATE users
      SET role = 'manager'
      WHERE role = 'manager_requests';
    SQL

    remove_column :users, :custom_permissions
  end
end
