Trestle.resource(:global_seo_settings, model: GlobalSeoSetting) do
  menu do
    item :global_seo_settings, icon: "fa fa-globe", label: "Глобальные SEO", group: "SEO", priority: 1
  end

  table do
    column :target_type do |setting|
      case setting.target_type
      when 'home' then 'Главная'
      when 'category' then 'Категории (общие)'
      when 'product' then 'Товары (общие)'
      when 'article' then 'Статьи (общие)'
      when 'static_page' then 'Служебные страницы'
      else setting.target_type
      end
    end
    column :title_template, label: "Шаблон Title"
    actions
  end

  form do |setting|
    tab :general, label: "Основные" do
      select :target_type, [
        ['Главная', 'home'],
        ['Категории (общие)', 'category'],
        ['Товары (общие)', 'product'],
        ['Статьи (общие)', 'article'],
        ['Служебные страницы', 'static_page']
      ], label: "Тип страницы"

      text_field :title_template, label: "Шаблон Title", help: "Используйте {{name}} для подстановки названия"
      text_area :description_template, label: "Шаблон Description"
      text_field :keywords_template, label: "Шаблон Keywords"
      text_field :robots, label: "Robots"
    end

    tab :seo_text, label: "SEO Текст" do
      tinymce :seo_text, label: "Текст внизу страницы"
    end
  end
end
