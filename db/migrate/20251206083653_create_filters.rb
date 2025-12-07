class CreateFilters < ActiveRecord::Migration[7.1]
  def change
    create_table :filters do |t|
      t.string :parameter
      t.string :name
      t.string :name_ru

      t.timestamps
    end
    add_index :filters, :parameter, unique: true
  end
end
