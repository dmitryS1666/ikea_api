# frozen_string_literal: true

module Admin
  # Единственный актуальный файл выгрузки в tmp/trestle_exports/ (при новой генерации старые xlsx там удаляются).
  class ProductsXlsxExportService
    EXPORT_DIR = Rails.root.join("tmp", "trestle_exports", "products_admin").freeze
    EXPORT_FILENAME = "products_by_category.xlsx".freeze

    class << self
      def export_path
        EXPORT_DIR.join(EXPORT_FILENAME)
      end

      def export_ready?
        export_path.file?
      end

      def exported_at
        export_ready? ? export_path.mtime : nil
      end

      # @param limit [Integer, nil] ограничение количества строк (например 5 для отладки)
      # @return [Pathname] путь к сохранённому файлу
      def build!(limit: nil)
        require "caxlsx"

        FileUtils.mkdir_p(EXPORT_DIR)
        remove_previous_exports!

        cp_map = last_category_ikea_id_by_product_id

        scope = Product.includes(:category).order(:id)
        scope = scope.limit(limit) if limit.present? && limit.positive?
        products = scope.to_a

        ikea_ids = products.map { |p| cp_map[p.id].presence || p.category_id }.compact.uniq
        categories_by_ikea = Category.where(ikea_id: ikea_ids).index_by(&:ikea_id)

        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        eur_rate = ExchangeRate.fetch_or_create("EUR")&.rate_per_unit
        buffer = PriceCalculationService.exchange_rate_buffer

        rows = products.map do |product|
          ikea_id = cp_map[product.id].presence || product.category_id
          cat = categories_by_ikea[ikea_id] || product.category
          category_label = cat&.translated_name.presence || cat&.name || "Без категории"

          price_zl = product.price.to_f
          weight = product.weight.to_f

          price_byn =
            if price_zl.positive?
              PriceCalculationService.product_price_byn(price_zl, pln_rate: pln_rate, buffer: buffer)
            else
              0.0
            end

          customs_total =
            if price_zl.positive? && weight.positive? && eur_rate.to_f.positive? && pln_rate.positive?
              price_eur = (price_zl * pln_rate / eur_rate).round(2)
              CustomsDutyService.calculate(price_eur, weight, eur_rate)[:total_byn]
            end

          {
            category_label: category_label,
            sku: product.sku,
            name: product.name_ru.presence || product.name,
            price_pln: price_zl,
            price_byn: price_byn,
            customs_byn: customs_total,
            url: product.url.to_s.presence
          }
        end

        rows.sort_by! { |r| [r[:category_label].to_s.downcase, r[:sku].to_s] }

        package = Axlsx::Package.new
        workbook = package.workbook
        bold = workbook.styles.add_style(b: true)

        workbook.add_worksheet(name: "Товары") do |sheet|
          sheet.add_row(
            [
              "Категория (последняя связь)",
              "SKU",
              "Название",
              "Цена PLN",
              "Цена сервиса BYN",
              "Таможня BYN (всего)",
              "Ссылка на товар"
            ],
            style: bold
          )

          prev_cat = nil
          rows.each do |r|
            if prev_cat && r[:category_label] != prev_cat
              sheet.add_row([])
            end

            sheet.add_row(
              [
                r[:category_label],
                r[:sku],
                r[:name],
                r[:price_pln],
                r[:price_byn],
                r[:customs_byn],
                r[:url]
              ]
            )
            prev_cat = r[:category_label]
          end
        end

        path = export_path
        package.serialize(path.to_s)
        path
      end

      private

      def remove_previous_exports!
        Dir.glob(EXPORT_DIR.join("*.xlsx")).each { |f| FileUtils.rm_f(f) }
      end

      def last_category_ikea_id_by_product_id
        sql = <<~SQL.squish
          SELECT DISTINCT ON (product_id) product_id, category_id
          FROM category_products
          ORDER BY product_id, updated_at DESC, id DESC
        SQL
        ActiveRecord::Base.connection.exec_query(sql).rows.to_h { |pid, cid| [pid.to_i, cid.to_s] }
      end
    end
  end
end
