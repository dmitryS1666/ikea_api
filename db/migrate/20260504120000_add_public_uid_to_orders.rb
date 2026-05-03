class AddPublicUidToOrders < ActiveRecord::Migration[7.1]
  def up
    add_column :orders, :public_uid, :string

    say_with_time "backfill orders.public_uid" do
      Order.reset_column_information
      Order.find_each do |order|
        next if order.public_uid.present?

        uid = nil
        loop do
          uid = random_public_uid
          break uid unless Order.where(public_uid: uid).where.not(id: order.id).exists?
        end
        order.update_column(:public_uid, uid)
      end
    end

    add_index :orders, :public_uid, unique: true
    change_column_null :orders, :public_uid, false
  end

  def down
    remove_index :orders, :public_uid
    remove_column :orders, :public_uid
  end

  def random_public_uid
    n = rand(6..8)
    min = 10**(n - 1)
    max = (10**n) - 1
    rand(min..max).to_s
  end
end
