class AddImageUrlToOrderItems < ActiveRecord::Migration[7.1]
  def change
    add_column :order_items, :image_url, :text
  end
end
