# app/controllers/admin/products_controller.rb
class Admin::ProductsController < ApplicationController
  # Если у вас есть стандартная админ-авторизация — подключи её тут, как в остальных админ-контроллерах.
  # before_action :authenticate_admin!

  # GET /admin/products/by_category?category_id=12345
  #
  # Возвращает упрощённый список товаров для выпадающих списков/автокомплита:
  # [{ sku: "...", name: "..." }, ...]
  #
  # category_id — это ikea_id категории (Category.primary_key = 'ikea_id')
  def by_category
    category_ikea_id = params[:category_id].to_s.strip
    return render(json: []) if category_ikea_id.blank?

    # Как на странице категории в Trestle: и products.category_id, и category_products
    # (joins(:categories) пропускал товары только с «основной» категорией без строки в join-таблице).
    products = Product
      .in_category_ikea_id(category_ikea_id)
      .distinct
      .order(:name, :sku)
      .limit(500)

    render json: products.map { |p|
      {
        sku: p.sku,
        name: (p.name.to_s.presence || p.sku),
        small_desc_name: p.small_desc_name.to_s.strip.presence
      }
    }
  end

  # GET /admin/products/search?q=table
  def search
    q = params[:q].to_s.strip
    sku_like = q.match?(/\A[\d\.]{2,}\z/)
    return render(json: []) if q.length < 3 && !sku_like

    products = Product.all
    if q.present?
      query = "%#{q}%"
      columns = %w[sku item_no name name_ru small_desc_name]
      columns << "small_desc_name_ru" if Product.column_names.include?("small_desc_name_ru")
      predicates = columns.map { |col| "COALESCE(#{col}::text, '') ILIKE :q" }.join(" OR ")
      products = products.where(predicates, q: query)
    end

    products = products.limit(50).order(:name)

    render json: products.map { |p|
      display_name = p.name.to_s.presence || p.sku
      extra = p.small_desc_name.to_s.strip
      label = extra.present? ? "#{display_name} — #{extra}" : display_name
      {
        id: p.sku,
        text: "#{label} (#{p.sku})",
        sku: p.sku,
        name: display_name,
        small_desc_name: extra.presence
      }
    }
  end
end
