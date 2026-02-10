Trestle.resource(:recommended_products, model: RecommendedProduct) do
  menu do
    item :recommended_products, icon: "fa fa-star", label: "Рекомендации (Корзина)", group: "Content"
  end

  table do
    column :product_sku, link: true
    column :position
    column :active do |rp|
      status_tag(rp.active ? 'Да' : 'Нет', rp.active ? :success : :secondary)
    end
    column :updated_at
    actions
  end

  form do |rp|
    text_field :product_sku
    number_field :position
    check_box :active
  end
end
