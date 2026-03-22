Trestle.admin(:dashboard) do
  menu do
    item :dashboard, icon: "fa fa-tachometer-alt", priority: :first, label: "Дашборд"
  end

  routes do
    get :stats
  end

  controller do
    def index
      @stats = DashboardStats.new.call
      @top_products = @stats[:top_products]
      @recent_orders = @stats[:recent_orders]
      @chart_data = @stats[:chart_data]
      @progress = @stats[:progress]
      
      render "admin/dashboard/index"
    end

    def stats
      render json: DashboardStats.new.call
    end
  end
end
