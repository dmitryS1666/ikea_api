Trestle.resource(:favorites) do
  menu do
    item :favorites, icon: "fa fa-heart", priority: 10, label: "Избранное (клиенты)", group: "Customers"
  end

  # Показываем только избранное авторизованных пользователей
  collection do
    Favorite.where.not(user_id: nil).includes(:user, :favorite_items)
  end

  table do
    column :id
    column :user, link: true
    column :items_count do |favorite|
      favorite.favorite_items.count
    end
    column :updated_at, align: :center
    actions
  end

  form do |favorite|
    static_field :user
    static_field :guest_token
    static_field :expires_at

    table favorite.favorite_items.includes(:product), label: "Товары в избранном" do
      column :product_sku
      column :product do |item|
        item.product&.name || "Товар не найден"
      end
      column :added_at, ->(item) { item.created_at }
    end
  end
end
