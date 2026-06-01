# Админ-панель для расчета цен (Обновленная логика Март 2026)
Trestle.resource(:price_calculator, model: PriceCalculator) do
  menu do
    item :price_calculator, icon: "fa fa-calculator", priority: 5, label: "Калькулятор цен", group: "Финансы"
  end

  controller do
    def index
      redirect_to admin.instance_path(PriceCalculator.new(id: "show"))
    end

    def show
      @calculation = nil
      @sku_calculation = nil
      @cart_calculation = nil
      @error = nil
      @calc_mode = params[:mode].presence || "manual"
      @current_rates = nil

      today = Date.today

      @params_info = {
        cheap_threshold_pln: PriceCalculationService.cheap_threshold_pln,
        cheap_multiplier: PriceCalculationService::CHEAP_MULTIPLIER,
        min_markup: PriceCalculationService::MIN_MARKUP,
        target_profit: PriceCalculationService::TARGET_PROFIT_PLN,
        markup_subtrahend: PriceCalculationService::MARKUP_SUBTRAHEND,
        buffer: CalculatorSetting.get("exchange_rate_buffer") || 1.05
      }

      @current_rates = load_current_rates(today)

      return render "trestle/price_calculator/show" unless params[:calculate]

      date = params[:date].present? ? Date.parse(params[:date]) : today

      case @calc_mode
      when "sku"
        run_sku_calculation(date)
      when "cart"
        run_cart_calculation(date)
      else
        run_manual_calculation(date)
      end

      render "trestle/price_calculator/show"
    rescue ArgumentError => e
      @error = "Некорректная дата: #{e.message}"
      render "trestle/price_calculator/show"
    rescue StandardError => e
      @error = "Ошибка расчета: #{e.message}"
      Rails.logger.error "Price calculation error: #{e.class} - #{e.message}\n#{e.backtrace.first(8).join("\n")}"
      render "trestle/price_calculator/show"
    end

    private

    def load_current_rates(today)
      rates = {}
      %w[USD EUR PLN].each do |currency|
        rate = ExchangeRate.fetch_or_create(currency, today)
        next unless rate

        rate_val = rate.rate_per_unit
        rates[currency.downcase.to_sym] = {
          nbrb: rate_val.round(4),
          with_buffer: (rate_val * @params_info[:buffer]).round(4),
          date: rate.date
        }
      end
      rates
    end

    def run_manual_calculation(date)
      product_price = params[:product_price]&.to_f
      weight = params[:weight]&.to_f
      use_gls = params[:use_gls] == "1"

      unless product_price&.positive? && weight&.positive?
        @error = "Укажите цену товара (в злотых) и вес (в кг)"
        return
      end

      delivery_pln = params[:delivery_pln].present? ? params[:delivery_pln].to_f : nil
      @calculation = PriceCalculationService.calculate(
        product_price,
        weight,
        use_gls_pickup: use_gls,
        delivery_pln: delivery_pln,
        date: date
      )

      if @calculation[:error]
        @error = @calculation[:error]
        @calculation = nil
      end
    end

    def run_sku_calculation(date)
      sku = params[:sku].to_s.strip
      quantity = params[:quantity].presence&.to_i || 1

      if sku.blank?
        @error = "Укажите SKU товара"
        return
      end

      product = Admin::PriceCalculatorService.find_product(sku)
      unless product
        @error = "Товар с SKU «#{sku}» не найден"
        return
      end

      delivery_pln = params[:delivery_pln].present? ? params[:delivery_pln].to_f : nil
      result = Admin::PriceCalculatorService.calculate_sku(
        product,
        quantity: quantity,
        use_gls_pickup: params[:use_gls] == "1",
        delivery_pln: delivery_pln,
        date: date
      )

      if result[:error]
        @error = result[:error]
        return
      end

      @sku_calculation = result
    end

    def run_cart_calculation(date)
      parsed = Admin::PriceCalculatorService.parse_cart_lines(params[:cart_lines])
      if parsed.errors.any?
        @error = parsed.errors.join("; ")
        return
      end

      if parsed.lines.empty?
        @error = "Добавьте позиции в корзину (по одной на строку: SKU и количество)"
        return
      end

      result = Admin::PriceCalculatorService.calculate_cart(parsed.lines, date: date)
      if result[:error]
        @error = result[:error]
        return
      end

      @cart_calculation = result
    end
  end
end
