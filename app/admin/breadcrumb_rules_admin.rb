Trestle.resource(:breadcrumb_rules, model: BreadcrumbRule) do
  menu do
    item :breadcrumb_rules, icon: "fa fa-list", priority: 1, label: "Правила хлебных крошек", group: "SEO"
  end

  table do
    column :entity_type
    column :rule_type do |rule|
      rule.rule_type.humanize
    end
    column :active do |rule|
      status_tag(rule.active? ? "Да" : "Нет", rule.active? ? :success : :secondary)
    end
    column :created_at, align: :center
    actions
  end

  form do |rule|
    tab :basic, label: "Основное" do
      static_field :hint, label: false do
        "build_tree: получает полную цепочку категорий (предки + актуальная категория)"
      end
      static_field :hint, label: false do
        "build_primary_category_only: только primary_category"
      end
      
      select :entity_type, BreadcrumbRule::ENTITY_TYPES.map { |entity| [entity.humanize, entity] }, label: "Тип сущности"
      select :rule_type, BreadcrumbRule.rule_types.keys.map { |type| [type.humanize, type] }, label: "Тип правила"
    end

    sidebar do
      form_group :status, label: "Статус" do
        check_box :active, label: "Активно"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
