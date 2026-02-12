Trestle.resource(:products, model: Product) do
  menu do
    item :products, icon: "fa fa-cube", priority: 2, label: "Продукты", group: "Catalog"
  end

  routes do
    get :by_category, on: :collection
  end

  scopes do
    scope :all, default: true
    scope :bestsellers, -> { Product.bestsellers }
    scope :popular, -> { Product.popular }
  end

  table do
    column :sku, link: true
    column :name
    column :name_ru
    column :category do |product|
      product.category&.name || 'Без категории'
    end
    column :price do |product|
      number_to_currency(product.price, unit: 'Zl', format: '%n %u')
    end
    column :quantity, sortable: true
    column :is_bestseller do |product|
      status_tag(product.is_bestseller? ? 'Да' : 'Нет', 
                 product.is_bestseller? ? :success : :secondary)
    end
    column :is_popular do |product|
      status_tag(product.is_popular? ? 'Да' : 'Нет', 
                 product.is_popular? ? :success : :secondary)
    end
    column :created_at, align: :center
    actions do |toolbar, instance, admin|
      toolbar.edit if admin.actions.include?(:edit)
      toolbar.delete if admin.actions.include?(:destroy)
    end
  end

  hook("resource.index.header") do
    render partial: "trestle/products/smart_search_panel"
  end

  controller do
    def show
      @product = admin.find_instance(params)
      render "trestle/products/show"
    end

    def by_category
      category_ikea_id = params[:category_id].to_s.strip
      return render(json: []) if category_ikea_id.blank?

      products = Product
        .joins(:categories)
        .where(categories: { ikea_id: category_ikea_id })
        .distinct
        .order(:name)
        .limit(500)

      render json: products.map { |p|
        { sku: p.sku, name: (p.name_ru.presence || p.sku) }
      }
    end
  end

  form do |product|
    tab :basic, label: "Основная информация" do
      text_field :sku
      text_field :unique_id
      text_field :item_no
      text_field :url
      text_field :name
      text_field :name_ru
      text_field :collection
      select :category_id, Category.all.map { |c| [c.name, c.ikea_id] }, { label: "Категория", include_blank: "Без категории" }
      
      form_group :categories, label: "Дополнительные категории" do
        select :category_ids, Category.all.map { |c| [c.name, c.ikea_id] }, { label: "Категории" }, { multiple: true, data: { ui: "select2" } }
      end
    end

    tab :pricing, label: "Цена и наличие" do
      number_field :price
      number_field :quantity
      text_field :home_delivery
      
      static_field :calculated_duty_info, label: "Таможенная пошлина (BYN)" do
        if product.price && product.weight
          eur_rate = ExchangeRate.fetch_or_create('EUR', Date.today)&.rate_per_unit
          pln_rate = ExchangeRate.fetch_or_create('PLN', Date.today)&.rate_per_unit
          if eur_rate && pln_rate
            price_eur = (product.price * pln_rate / eur_rate).round(2)
            calculation = CustomsDutyService.calculate(price_eur, product.weight, eur_rate)
            "#{calculation[:total_byn]} BYN (Пошлина: #{calculation[:duty_byn]} + Сбор: #{calculation[:fee_byn]})"
          else
            "Курсы валют не найдены"
          end
        else
          "Недостаточно данных для расчета"
        end
      end
    end

    tab :specs, label: "Характеристики" do
      number_field :weight
      number_field :net_weight
      number_field :package_volume
      text_field :package_dimensions
      text_field :dimensions
      check_box :is_parcel
    end

    tab :flags, label: "Флаги" do
      check_box :is_bestseller
      check_box :is_popular
      check_box :translated
      number_field :popularity_score
      number_field :views_count
      number_field :sales_count
    end

    tab :delivery, label: "Доставка" do
      text_field :delivery_type
      text_field :delivery_name
      number_field :delivery_cost
      text_field :delivery_reason
    end
  end

end

