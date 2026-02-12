class AddDeliveryDaysToCategoriesAndSettings < ActiveRecord::Migration[7.1]
  def change
    add_column :categories, :delivery_days, :integer
  end
end
