class CreateCooperationRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :cooperation_requests do |t|
      t.string :name, null: false
      t.string :phone
      t.string :email
      t.string :company
      t.string :city
      t.text :message, null: false
      t.string :status, null: false, default: 'new'

      t.timestamps
    end

    add_index :cooperation_requests, :status
    add_index :cooperation_requests, :created_at
  end
end

