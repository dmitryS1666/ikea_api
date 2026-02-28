Trestle.resource(:promo_code_products, model: PromoCodeProduct) do
  menu do
    item :promo_code_products, icon: "fa fa-link", label: "Промо-артикулы", group: "Marketing"
  end

  table do
    column :promo_code do |record|
      record.promo_code&.code
    end
    column :product_sku
    column :created_at
    actions
  end

  form do |promo_code_product|
    select :promo_code_id, PromoCode.all.map { |promo| [promo.code, promo.id] }, label: "Промокод"
    
    divider

    text_field :product_sku, label: "Единичный SKU (заполните, если добавляете один товар)"
    
    file_field :csv_file, label: "Загрузить список SKU через CSV (один артикул на строку)", accept: ".csv"
    
    select :category_id, Category.active.order(:name).map { |c| ["#{c.name} (#{c.ikea_id})", c.ikea_id] }, 
           label: "ИЛИ Выберите категорию (промокод будет действовать на все товары в ней)", 
           include_blank: "--- Не выбирать ---",
           help: "При выборе категории будет создана постоянная привязка промокода к данной категории."
  end

  controller do
    def create
      promo_id = params[:promo_code_product][:promo_code_id]
      sku = params[:promo_code_product][:product_sku]
      csv_file = params[:promo_code_product][:csv_file]
      category_id = params[:promo_code_product][:category_id]

      if promo_id.blank?
        flash[:error] = "Выберите промокод"
        redirect_to _helpers.new_admin_promo_code_product_path and return
      end

      begin
        if category_id.present?
          PromoCodeCategory.find_or_create_by!(promo_code_id: promo_id, category_id: category_id)
          flash[:message] = "Категория успешно привязана к промокоду"
          redirect_to Trestle.lookup(:promo_code_categories).path(:index) and return
        elsif csv_file.present?
          require 'csv'
          count = 0
          CSV.foreach(csv_file.path) do |row|
            s = row[0].to_s.strip
            next if s.blank?
            PromoCodeProduct.find_or_create_by!(promo_code_id: promo_id, product_sku: s)
            count += 1
          end
          flash[:message] = "Успешно добавлено #{count} артикулов из CSV"
        elsif sku.present?
          PromoCodeProduct.find_or_create_by!(promo_code_id: promo_id, product_sku: sku.strip)
          flash[:message] = "Артикул успешно добавлен"
        else
          flash[:error] = "Укажите SKU, выберите CSV файл или категорию"
          redirect_to admin.path(:new) and return
        end
      rescue => e
        flash[:error] = "Ошибка: #{e.message}"
        redirect_to admin.path(:new) and return
      end

      redirect_to admin.path(:index)
    end
  end
end
