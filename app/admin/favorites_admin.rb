Trestle.resource(:favorites) do
  menu do
    item :favorites, icon: "fa fa-heart", priority: 10, label: "Избранное (клиенты)", group: "Клиенты"
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
    tab :basic, label: "Основное" do
      static_field :user, label: "Пользователь"
      static_field :guest_token, label: "Гостевой токен"
      static_field :expires_at, label: "Истекает"
    end

    tab :items, label: "Товары" do
      table favorite.favorite_items.includes(:product) do
        column :product_sku
        column :product do |item|
          item.product&.name || "Товар не найден"
        end
        column :created_at, align: :center
      end
    end
  end
end
