class CreateCategoryCleanupRules < ActiveRecord::Migration[7.1]
  def change
    create_table :category_cleanup_rules do |t|
      t.integer :source_row_no, null: false
      t.string  :source_ikea_id
      t.string  :source_url
      t.text    :raw_status, null: false

      t.string  :action, null: false # keep / delete / merge / skip / review
      t.integer :target_row_no
      t.string  :target_ikea_id

      t.string  :resolution_status, null: false, default: 'pending'
      # pending / resolved / ambiguous / failed / applied / skipped

      t.string  :resolved_source_ikea_id
      t.string  :resolved_target_ikea_id

      t.string  :source_matched_by
      t.string  :target_matched_by

      t.text    :notes
      t.jsonb   :meta, null: false, default: {}

      t.timestamps
    end

    add_index :category_cleanup_rules, :source_row_no, unique: true
    add_index :category_cleanup_rules, :action
    add_index :category_cleanup_rules, :resolution_status
    add_index :category_cleanup_rules, :resolved_source_ikea_id
    add_index :category_cleanup_rules, :resolved_target_ikea_id
  end
end
