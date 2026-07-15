# frozen_string_literal: true

Trestle.resource(:europost_tester, model: EuropostTester) do
  menu do
    item :europost_tester, icon: "fa fa-truck", priority: 6, label: "Тест Европочты", group: "Финансы",
                           if: -> { current_user&.allowed_for_admin_resource?(:europost_tester, :index) }
  end

  controller do
    def index
      redirect_to admin.instance_path(EuropostTester.new(id: "show"))
    end

    def show
      @defaults = Admin::EuropostTesterService.default_params
      @form_params = @defaults.merge(params.to_unsafe_h.slice(*@defaults.keys))
      @env_status = Admin::EuropostTesterService.env_status
      @stores = []
      @quote_result = nil
      @create_result = nil
      @error = nil

      if params[:load_stores].present? || params[:calculate].present? || params[:create_shipment].present?
        @stores = Admin::EuropostTesterService.load_stores(type: params[:store_type].presence || @form_params["store_type"])
      end

      if params[:calculate].present?
        @quote_result = Admin::EuropostTesterService.calculate(params)
      elsif params[:create_shipment].present?
        @create_result = Admin::EuropostTesterService.create_shipment(params)
      end

      render "trestle/europost_tester/show"
    rescue StandardError => e
      @error = "Ошибка тестера Европочты: #{e.class}: #{e.message}"
      Rails.logger.error("[EUROPOST_TESTER] #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}")
      render "trestle/europost_tester/show"
    end
  end
end
