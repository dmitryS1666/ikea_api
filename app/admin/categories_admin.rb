Trestle.resource(:categories, model: Category) do
  menu do
    item :categories, icon: "fa fa-folder", priority: 2
  end

  table do
    column :ikea_id
    column :name, link: true
    column :name_ru
    column :is_popular do |category|
      status_tag(category.is_popular? ? 'Да' : 'Нет', 
                 category.is_popular? ? :success : :secondary)
    end
    column :is_deleted do |category|
      status_tag(category.is_deleted? ? 'Удалена' : 'Активна', 
                 category.is_deleted? ? :danger : :success)
    end
    column :products_count do |category|
      category.products.count
    end
    column :created_at, align: :center
    actions
  end

  form do |category|
    text_field :ikea_id
    text_field :name
    text_field :name_ru
    check_box :is_popular
    check_box :is_deleted
    text_area :parent_ids, label: "Parent IDs (JSON)"
  end

end

