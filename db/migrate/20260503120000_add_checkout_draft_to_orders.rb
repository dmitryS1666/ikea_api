class AddCheckoutDraftToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :checkout_draft, :boolean, default: false, null: false
    add_index :orders, [:user_id, :checkout_draft],
              where: "checkout_draft = true",
              name: "index_orders_on_user_id_where_checkout_draft"
  end
end
