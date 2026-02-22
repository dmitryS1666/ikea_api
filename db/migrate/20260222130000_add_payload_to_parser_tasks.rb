class AddPayloadToParserTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :parser_tasks, :payload, :jsonb, default: {}, null: false
  end
end
