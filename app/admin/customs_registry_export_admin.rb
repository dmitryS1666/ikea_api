# frozen_string_literal: true

Trestle.resource(:customs_registry_export, model: CustomsRegistryExport) do
  menu do
    item :customs_registry_export,
         icon: "fa fa-file-excel",
         priority: 4,
         label: "Реестр (таможня)",
         group: :sales,
         if: -> { current_user&.allowed_for_admin_resource?(:customs_registry_export, :index) }
  end

  routes do
    get :download, on: :collection
  end

  controller do
    def index
      redirect_to admin.instance_path(CustomsRegistryExport.new(id: "show"))
    end

    def show
      @from_date = params[:from_date].presence || Date.current.beginning_of_month.to_s
      @to_date = params[:to_date].presence || Date.current.to_s
      @error = nil
      @orders_count = nil

      if params[:preview].present?
        begin
          @orders_count = Admin::CustomsRegistryXlsxExport.count_orders(
            from_date: @from_date,
            to_date: @to_date
          )
        rescue ArgumentError => e
          @error = e.message
        end
      end

      render "trestle/customs_registry_export/show"
    end

    def download
      unless current_user&.allowed_for_admin_resource?(:customs_registry_export, :download) &&
             current_user&.can_view_personal_data?
        flash[:error] = "Недостаточно прав для выгрузки реестра"
        return redirect_to admin.instance_path(
          CustomsRegistryExport.new(id: "show"),
          from_date: params[:from_date],
          to_date: params[:to_date]
        )
      end

      result = Admin::CustomsRegistryXlsxExport.call(
        from_date: params[:from_date],
        to_date: params[:to_date]
      )

      filename = "customs-registry-#{result.from_date.iso8601}_#{result.to_date.iso8601}.xlsx"
      send_data(
        result.xlsx,
        filename: filename,
        type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        disposition: "attachment"
      )
    rescue ArgumentError => e
      flash[:error] = e.message
      redirect_to admin.instance_path(
        CustomsRegistryExport.new(id: "show"),
        from_date: params[:from_date],
        to_date: params[:to_date]
      )
    end
  end
end
