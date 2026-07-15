Trestle.resource(:promo_codes, model: PromoCode) do
  menu do
    item :promo_codes, icon: "fa fa-percent", group: :sales, label: "Промокоды",
                       if: -> { current_user&.allowed_for_admin_resource?(:promo_codes, :index) }
  end

  table do
    column :code, link: true
    column :name
    column :discount_type do |pc|
      I18n.t("activerecord.attributes.promo_code.discount_types.#{pc.discount_type}", default: pc.discount_type)
    end
    column :discount_value do |promo_code|
      number_to_currency(promo_code.discount_value, unit: 'BYN', format: '%n %u')
    end
    column :active do |promo_code|
      status_tag(promo_code.active? ? 'Да' : 'Нет', promo_code.active? ? :success : :secondary)
    end
    column :starts_at
    column :ends_at
    column :updated_at, align: :center
    actions
  end

  form do |promo_code|
    tab :basic, label: "Основное" do
      row do
        col(sm: 6) do
          text_field :code, label: "Промокод (код)"
          text_field :name, label: "Название (описание)"
        end
        col(sm: 6) do
          select :discount_type, PromoCode.discount_types.keys.map { |type| [I18n.t("activerecord.attributes.promo_code.discount_types.#{type}", default: type.humanize), type] }
          number_field :discount_value, step: 0.01
        end
      end
    end

    sidebar do
      form_group :status, label: "Статус" do
        check_box :active, label: "Активен"
      end

      form_group :validity, label: "Период действия" do
        datetime_field :starts_at, label: "Дата начала"
        datetime_field :ends_at, label: "Дата окончания"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
