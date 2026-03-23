# Админ-панель для управления курсами валют
Trestle.resource(:exchange_rates, model: ExchangeRate) do
  paginate per_page: 31

  menu do
    item :exchange_rates, icon: "fa fa-dollar-sign", group: :content, label: "Курсы валют"
  end

  table do
    column :date, sort: { default: true, direction: :desc }
    column :currency_code
    column :rate, label: "Курс НБРБ" do |rate|
      number_with_precision(rate.rate, precision: 4)
    end
    column :scale
    column :rate_per_unit do |rate|
      number_with_precision(rate.rate_per_unit, precision: 4)
    end
    column :created_at, label: "Загружен", align: :center
    actions
  end

  controller do
    def index
      super
      @current_rates = {}
      today = Date.today
      margin = CalculatorSetting.get('margin_multiplier') || 1.1
      
      # Получаем актуальные курсы для основных валют
      ['USD', 'EUR', 'PLN'].each do |currency|
        rate = ExchangeRate.fetch_or_create(currency, today)
        if rate
          @current_rates[currency] = {
            nbrb: rate.rate_per_unit.round(4),
            with_margin: (rate.rate_per_unit * margin).round(4),
            date: rate.date,
            scale: rate.scale,
            official_rate: rate.rate
          }
        end
      end
      
      render "trestle/exchange_rates/index"
    end
    
    def sync
      date = params[:date].present? ? Date.parse(params[:date]) : Date.today
      
      # Обрабатываем параметр currencies (может быть массивом или строкой)
      currencies = if params[:currencies].is_a?(Array)
        params[:currencies]
      elsif params[:currencies].is_a?(String)
        params[:currencies].split
      else
        ['USD', 'EUR', 'PLN']
      end
      
      synced = []
      errors = []
      
      currencies.each do |currency|
        begin
          rate = ExchangeRate.fetch_or_create(currency, date)
          if rate
            synced << "#{currency}: #{rate.rate_per_unit.round(4)}"
          else
            errors << "Не удалось получить курс для #{currency}"
          end
        rescue => e
          errors << "Ошибка для #{currency}: #{e.message}"
        end
      end
      
      if errors.empty?
        flash[:message] = "Курсы обновлены: #{synced.join(', ')}"
      else
        flash[:error] = "Ошибки: #{errors.join(', ')}"
      end
      
      redirect_to admin.path(:index)
    end
  end

  routes do
    post :sync, on: :collection
  end

  form do |rate|
    tab :basic, label: "Основное" do
      date_field :date
      select :currency_code, [['USD', 'USD'], ['EUR', 'EUR'], ['PLN', 'PLN'], ['RUB', 'RUB']]
      number_field :rate, step: 0.0001, label: "Курс НБРБ"
      number_field :official_rate, step: 0.0001, label: "Официальный курс"
      number_field :scale
    end

    sidebar do
      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата загрузки"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end
end

