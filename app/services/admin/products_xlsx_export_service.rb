# frozen_string_literal: true

module Admin
  # Единственный актуальный файл выгрузки в tmp/trestle_exports/ (при новой генерации старые xlsx там удаляются).
  class ProductsXlsxExportService
    EXPORT_DIR = Rails.root.join("tmp", "trestle_exports", "products_admin").freeze
    EXPORT_FILENAME = "products_by_category.xlsx".freeze

    COL_LAST = "F" # 6 колонок: A–F

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

        item_rows = products.map do |product|
          ikea_id = cp_map[product.id].presence || product.category_id
          cat = categories_by_ikea[ikea_id] || product.category
          category_label = cat&.translated_name.presence || cat&.name || "Без категории"

          price_zl = product.price.to_f
          weight = product.weight.to_f

          price_byn =
            if price_zl.positive?
              PriceCalculationService.product_price_byn(
                price_zl,
                weight_kg: weight,
                delivery_pln: product.delivery_cost.to_f,
                pln_rate: pln_rate,
                buffer: buffer
              )
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
            display_name: display_name_for(product),
            price_pln: price_zl,
            price_byn: price_byn,
            customs_byn: customs_total,
            url: product.url.to_s.presence
          }
        end

        item_rows.sort_by! { |r| [r[:category_label].to_s.downcase, r[:sku].to_s] }
        groups = item_rows.slice_when { |a, b| a[:category_label] != b[:category_label] }.to_a

        package = Axlsx::Package.new
        workbook = package.workbook
        styles = workbook.styles

        title_style = styles.add_style(
          b: true,
          sz: 14,
          fg_color: "333333",
          alignment: { horizontal: :left, vertical: :center, wrap_text: true }
        )
        meta_style = styles.add_style(
          sz: 10,
          fg_color: "666666",
          alignment: { horizontal: :left, vertical: :center, wrap_text: true }
        )
        category_band_style = styles.add_style(
          b: true,
          sz: 12,
          fg_color: "222222",
          bg_color: "E8E8E8",
          border: { style: :thin, color: "C0C0C0" },
          alignment: { horizontal: :left, vertical: :center, wrap_text: true }
        )
        subheader_style = styles.add_style(
          b: true,
          bg_color: "F5F5F5",
          fg_color: "333333",
          border: { style: :thin, color: "C0C0C0" },
          alignment: { horizontal: :left, vertical: :center, wrap_text: true }
        )

        data_row_styles = build_zebra_data_row_styles(styles)

        workbook.add_worksheet(name: "Товары") do |sheet|
          excel_row = 1

          title_text = "Каталог товаров по категориям (последняя связь category_products)"
          sheet.add_row([title_text] + [nil] * 5, style: title_style)
          sheet.merge_cells("A#{excel_row}:#{COL_LAST}#{excel_row}")
          excel_row += 1

          meta = "Сформировано: #{Time.zone.now.strftime('%d.%m.%Y %H:%M')} (#{Time.zone.name}) · товаров: #{item_rows.size}"
          sheet.add_row([meta] + [nil] * 5, style: meta_style)
          sheet.merge_cells("A#{excel_row}:#{COL_LAST}#{excel_row}")
          excel_row += 1

          sheet.add_row([])
          excel_row += 1

          groups.each_with_index do |group, group_idx|
            cat_label = group.first[:category_label]

            sheet.add_row([cat_label] + [nil] * 5, style: category_band_style)
            sheet.merge_cells("A#{excel_row}:#{COL_LAST}#{excel_row}")
            excel_row += 1

            sheet.add_row(
              [
                "SKU",
                "Название",
                "Цена PLN",
                "Цена сервиса BYN",
                "Таможня BYN (всего)",
                "Ссылка на товар"
              ],
              style: Array.new(6, subheader_style)
            )
            excel_row += 1

            group.each_with_index do |r, idx|
              row_styles = idx.even? ? data_row_styles[:even] : data_row_styles[:odd]
              sheet.add_row(
                [
                  r[:sku],
                  r[:display_name],
                  r[:price_pln].positive? ? r[:price_pln] : nil,
                  r[:price_byn].positive? ? r[:price_byn] : nil,
                  r[:customs_byn],
                  r[:url]
                ],
                style: row_styles
              )
              excel_row += 1
            end

            sheet.add_row([]) if group_idx < groups.length - 1
            excel_row += 1 if group_idx < groups.length - 1
          end

          sheet.column_widths 14, 52, 14, 28, 26, 80
        end

        path = export_path
        package.serialize(path.to_s)
        path
      end

      def display_name_for(product)
        base = product.name_ru.presence || product.name.to_s
        short = product.small_desc_name.to_s.strip
        short.present? ? "#{base} (#{short})" : base
      end

      private

      def build_zebra_data_row_styles(styles)
        mk = lambda do |bg|
          [
            styles.add_style(
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :left, vertical: :center }
            ),
            styles.add_style(
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :left, vertical: :top, wrap_text: true }
            ),
            styles.add_style(
              format_code: "#,##0.00",
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :right, vertical: :center }
            ),
            styles.add_style(
              format_code: "#,##0.00",
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :right, vertical: :center }
            ),
            styles.add_style(
              format_code: "#,##0.00",
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :right, vertical: :center }
            ),
            styles.add_style(
              fg_color: "0563C1",
              u: true,
              border: { style: :thin, color: "D8D8D8" },
              bg_color: bg,
              alignment: { horizontal: :left, vertical: :top, wrap_text: true }
            )
          ]
        end

        { even: mk.call("FFFFFF"), odd: mk.call("FAFAFA") }
      end

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
