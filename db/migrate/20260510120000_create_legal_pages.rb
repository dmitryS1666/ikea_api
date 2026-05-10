class CreateLegalPages < ActiveRecord::Migration[7.1]
  def up
    create_table :legal_pages do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :body
      t.integer :status, null: false, default: 0
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :legal_pages, :slug, unique: true
    add_index :legal_pages, [:status, :position]

    LegalPage.reset_column_information
    LegalPage.seed_defaults!
  end

  def down
    drop_table :legal_pages
  end
end
