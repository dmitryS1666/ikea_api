class DashboardStats
  require 'groupdate'

  def initialize(user: nil)
    @user = user
  end
  
  def call
    {
      revenue: finance_access? ? revenue : nil,
      new_clients: new_clients,
      active_products: active_products,
      avg_check: finance_access? ? avg_check : nil,
      orders_count: orders_count,
      chart_data: chart_data,
      top_products: top_products,
      recent_orders: recent_orders,
      progress: progress
    }
  end

  private

  def revenue
    Order.where(created_at: 30.days.ago..Time.current).sum(:total_amount).to_f
  end

  def new_clients
    User.where(created_at: 30.days.ago..Time.current, role: 'user').count
  end

  def active_products
    Product.count # Adjust if there's an active scope
  end

  def avg_check
    return 0 if orders_count.zero?
    revenue / orders_count
  end

  def orders_count
    @orders_count ||= Order.where(created_at: 30.days.ago..Time.current).count
  end

  def chart_data
    # Using groupdate
    Order.where(created_at: 30.days.ago..Time.current)
         .group_by_day(:created_at)
         .count
         .map { |date, count| { date: date.strftime("%d.%m"), count: count } }
  end

  def top_products
    Product.order(views_count: :desc).limit(5).map do |p|
      { id: p.id, name: p.name_ru || p.name, views: p.views_count, sku: p.sku }
    end
  end

  def recent_orders
    Order.order(created_at: :desc).limit(4).map do |o|
      {
        id: o.id,
        customer: personal_data_access? ? o.customer_name : "Скрыто",
        total: o.total_amount.to_f,
        status: o.status,
        created_at: o.created_at
      }
    end
  end

  def progress
    {
      catalog: catalog_completion,
      orders: order_processing_rate,
      reviews: review_response_rate
    }
  end

  def catalog_completion
    total = Product.count
    return 0 if total.zero?
    # Example: percentage of products with images and description
    filled = Product.where.not(content_ru: [nil, ""]).where.not(images: [nil, "[]", ""]).count
    (filled.to_f / total * 100).round(1)
  end

  def order_processing_rate
    total = Order.where(created_at: 30.days.ago..Time.current).count
    return 0 if total.zero?
    processed = Order.where(created_at: 30.days.ago..Time.current)
                    .where(status: [:processing, :confirmed, :paid, :purchased, :received_poland, :export_eu, :customs_poland, :on_border, :customs_belarus, :shipped, :arrived_pvz, :handed_to_courier, :handed_to_courier_ikeya, :completed])
                     .count
    (processed.to_f / total * 100).round(1)
  end

  def review_response_rate
    total = Review.count
    return 0 if total.zero?
    responded = Review.where.not(admin_note: [nil, ""]).count
    (responded.to_f / total * 100).round(1)
  end

  def finance_access?
    @user.nil? || @user.has_admin_permission?(:finance_view)
  end

  def personal_data_access?
    @user.nil? || (@user.can_view_personal_data? && @user.has_admin_permission?(:orders_manage))
  end
end
