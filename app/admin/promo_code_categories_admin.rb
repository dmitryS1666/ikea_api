Trestle.resource(:promo_code_categories, model: PromoCodeCategory) do
  menu do
    item :promo_code_categories, icon: "fa fa-folder-open", label: "Промо-категории", group: "Маркетинг"
  end

  table do
    column :promo_code, label: "Промокод" do |record|
      record.promo_code&.code
    end
    column :category, label: "Категория" do |record|
      record.category&.name || record.category_id
    end
    column :created_at, label: "Дата привязки", align: :center
    actions
  end

  form do |promo_code_category|
    select :promo_code_id, PromoCode.all.map { |promo| [promo.code, promo.id] }, label: "Промокод"
    select :category_id, Category.active.order(:name).map { |c| ["#{c.name} (#{c.ikea_id})", c.ikea_id] }, label: "Категория"
  end
end
