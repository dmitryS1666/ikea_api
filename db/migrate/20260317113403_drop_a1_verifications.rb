class DropA1Verifications < ActiveRecord::Migration[7.1]
  def up
    drop_table :a1_verifications if table_exists?(:a1_verifications)
  end

  def down
    # No going back easily
    raise ActiveRecord::IrreversibleMigration
  end
end
