class BackfillOrderItemImageUrls < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    return unless column_exists?(:order_items, :image_url)

    OrderItem.reset_column_information

    OrderItem
      .includes(:product)
      .where(image_url: [nil, ""])
      .find_each(batch_size: 500) do |order_item|
        image_url = OrderItemImageSnapshot.for_product(order_item.product)
        next if image_url.blank?

        order_item.update_columns(
          image_url: image_url,
          updated_at: Time.current
        )
      end
  end

  def down
    # no-op: image_url — безопасный snapshot, при rollback не очищаем
  end
end
