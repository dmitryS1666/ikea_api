class CreateFilterValues < ActiveRecord::Migration[7.1]
  def change
    create_table :filter_values do |t|
      t.references :filter, null: false, foreign_key: true
      t.string :value_id
      t.string :name
      t.string :name_ru
      t.string :hex

      t.timestamps
    end
    add_index :filter_values, :value_id, unique: true
  end
end
