Trestle.resource(:favorites) do
  menu do
    item :favorites, icon: "fa fa-heart", priority: 10, label: "Избранное (клиенты)", group: "Клиенты"
  end

  # Показываем только избранное авторизованных пользователей
  collection do
    Favorite.where.not(user_id: nil).includes(:user, :favorite_items)
  end

  table do
    column :id, label: "ID"
    column :user, label: "Пользователь", link: true
    column :items_count, label: "Товаров" do |favorite|
      favorite.favorite_items.count
    end
    column :updated_at, label: "Обновлено", align: :center
    actions
  end

  form do |favorite|
    tab :basic, label: "Основное" do
      static_field :user, label: "Пользователь"
      static_field :guest_token, label: "Гостевой токен"
      static_field :expires_at, label: "Истекает"
    end

    tab :items, label: "Товары" do
      table favorite.favorite_items.includes(:product), label: "Товары в избранном" do
        column :product_sku, label: "SKU"
        column :product, label: "Товар" do |item|
          item.product&.name || "Товар не найден"
        end
        column :added_at, label: "Добавлен" do |item|
          item.created_at
        end
      end
    end
  end
end
