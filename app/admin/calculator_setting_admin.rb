Trestle.resource(:calculator_setting, model: CalculatorSetting) do
  menu do
    item :calculator_setting, icon: "fa fa-cog", group: :content, label: "Системные настройки",
                              if: -> { current_user&.allowed_for_admin_resource?(:calculator_setting, :index) }
  end

  table do
    column :key
    column :description
    column :value do |setting|
      truncate(setting.value.to_s, length: 80)
    end
    column :updated_at, align: :center
    actions
  end

  form do |setting|
    tab :basic, label: "Настройка" do
      static_field :key, label: "Ключ настройки"
      static_field :group_label, label: "Группа"

      if setting.key&.end_with?("_global")
        select :value, [["Включено", "1"], ["Выключено", "0"]], label: "Значение"
      elsif setting.setting_type == "json" || CalculatorSetting::JSON_KEYS.include?(setting.key)
        text_area :value, rows: 16, label: "Значение (JSON)"
      elsif setting.setting_type == "integer"
        number_field :value, step: 1, label: "Целое значение"
      else
        number_field :value, step: 0.0001, label: "Числовое значение"
      end

      text_area :description, rows: 3, label: "Описание"
    end

    sidebar do
      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
        static_field :setting_type, label: "Тип"
      end
    end
  end

  controller do
    def initialize_defaults
      created_before = CalculatorSetting.count
      CalculatorSetting.initialize_defaults
      created_after = CalculatorSetting.count
      flash[:message] = "Добавлены только отсутствующие настройки (#{created_after - created_before} новых). Существующие значения не изменены."
      redirect_to admin.path(:index)
    end
  end

  routes do
    post :initialize_defaults, on: :collection
  end
end
