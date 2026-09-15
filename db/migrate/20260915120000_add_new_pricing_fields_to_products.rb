# frozen_string_literal: true

class AddNewPricingFieldsToProducts < ActiveRecord::Migration[7.1]
  def up
    add_column :products, :price_addon_pln, :decimal, precision: 12, scale: 2, null: false, default: 0
    add_column :products, :delivery_cost_manual, :boolean, null: false, default: false
  end

  def down
    remove_column :products, :delivery_cost_manual
    remove_column :products, :price_addon_pln
  end
end
