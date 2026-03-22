Trestle.resource(:calculator_setting, model: CalculatorSetting) do
  menu do
    item :calculator_setting, icon: "fa fa-cog", group: :content, label: "Системные настройки"
  end

  table do
    column :key, label: "Ключ"
    column :value, label: "Значение"
    column :updated_at, label: "Обновлено", align: :center
    actions
  end

  form do |setting|
    tab :basic, label: "Настройка" do
      static_field :key, label: "Ключ настройки"
      
      if setting.key&.end_with?('_global')
        select :value, [['Включено', '1'], ['Выключено', '0']], label: "Значение"
      elsif %w[belarus_delivery_rates poland_delivery_rates].include?(setting.key)
        text_area :value, rows: 10, label: "Значение (JSON)"
      else
        number_field :value, step: 0.0001, label: "Числовое значение"
      end
      
      text_field :description, label: "Описание"
    end

    sidebar do
      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end
