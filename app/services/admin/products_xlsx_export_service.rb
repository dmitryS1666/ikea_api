# frozen_string_literal: true

module Admin
  # Единственный актуальный файл выгрузки в tmp/trestle_exports/ (при новой генерации старые xlsx там удаляются).
  class ProductsXlsxExportService
    EXPORT_DIR = Rails.root.join("tmp", "trestle_exports", "products_admin").freeze
    EXPORT_FILENAME = "products_by_category.xlsx".freeze
    EXPORT_TMP_FILENAME = "products_by_category.xlsx.tmp".freeze

    CATALOG_SHEET = "Товары"
    DATA_SHEET = "Данные"
    CALC_SHEET = "Калькулятор"
    CATALOG_COL_LAST = "H" # A–H: SKU, название, размеры, вес, PLN, BYN, таможня, ссылка

    # Плоская таблица на листе «Данные» (строка 1 — заголовки, данные с 2)
    DATA_HEADERS = [
      "SKU",
      "Название",
      "Размеры",
      "Вес упаковки (кг)",
      "Объём (м³)",
      "Макс. сторона (см)",
      "Цена IKEA (PLN)",
      "delivery_cost (PLN)",
      "Режим цены",
      "Наценка K",
      "Товар (PLN)",
      "Доставка PL в цене (PLN)",
      "Логистика РБ WC_BY (PLN)",
      "Итого PLN",
      "Курс PLN→BYN",
      "Буфер курса",
      "Курс × буфер",
      "Цена товара (BYN)",
      "Доставка до Беларуси (BYN)",
      "Доставка PL в цене (BYN)",
      "Цена сервиса (BYN)",
      "Таможня (BYN)",
      "ВГХ: вес OK",
      "ВГХ: объём OK",
      "ВГХ: сторона OK",
      "Статус ВГХ"
    ].freeze

    # Лист «Данные»: строка 1 — пояснение, строка 2 — заголовки, с 3 — товары.
    DATA_FIRST_ROW = 3
    BUILD_LOCK = EXPORT_DIR.join(".building.lock")
    PROGRESS_FILE = EXPORT_DIR.join(".export_progress.json")
    LAST_ERROR_FILE = EXPORT_DIR.join(".export_last_error.txt")

    class AlreadyBuilding < StandardError; end

    class << self
      def building?
        return false unless BUILD_LOCK.file?

        File.open(BUILD_LOCK, File::CREAT | File::RDWR) do |lock|
          if lock.flock(File::LOCK_EX | File::LOCK_NB)
            lock.flock(File::LOCK_UN)
            FileUtils.rm_f(BUILD_LOCK)
            false
          else
            true
          end
        end
      rescue StandardError
        false
      end
      def export_path
        EXPORT_DIR.join(EXPORT_FILENAME)
      end

      def export_ready?
        path = export_path
        path.file? && path.size.positive?
      end

      def exported_at
        export_ready? ? export_path.mtime : nil
      end

      def export_progress
        return nil unless PROGRESS_FILE.file?

        JSON.parse(PROGRESS_FILE.read)
      rescue StandardError
        nil
      end

      def export_last_error
        return nil unless LAST_ERROR_FILE.file?

        msg = LAST_ERROR_FILE.read.strip.presence
        return nil if msg.blank?
        return nil if !building? && msg.start_with?("AlreadyBuilding", "Admin::ProductsXlsxExportService::AlreadyBuilding")

        msg
      end

      # Сброс lock/прогресса, если выгрузка не идёт (зависший lock после kill Sidekiq).
      def reset_export_state!
        raise AlreadyBuilding, "Выгрузка XLSX сейчас выполняется — дождитесь завершения" if building?

        clear_export_progress!
        clear_export_error!
        FileUtils.rm_f(BUILD_LOCK)
        true
      end

      def export_status_label
        if building?
          prog = export_progress
          if prog && prog["total"].to_i.positive?
            "⏳ Выгрузка: #{prog['processed']}/#{prog['total']} (#{prog['phase']}) — обновите страницу"
          else
            "⏳ Выгрузка XLSX выполняется… обновите страницу"
          end
        elsif export_last_error.present?
          "Ошибка последней выгрузки: #{export_last_error}"
        end
      end

      # @param limit [Integer, nil] ограничение количества строк (например 5 для отладки)
      # @return [Pathname] путь к сохранённому файлу
      def build!(limit: nil)
        require "caxlsx"

        FileUtils.mkdir_p(EXPORT_DIR)
        lock_fd = nil
        skipped_due_to_lock = false
        lock_fd = File.open(BUILD_LOCK, File::CREAT | File::RDWR)
        unless lock_fd.flock(File::LOCK_EX | File::LOCK_NB)
          lock_fd.close
          lock_fd = nil
          skipped_due_to_lock = true
          raise AlreadyBuilding, "Выгрузка XLSX уже выполняется"
        end

        cp_map = last_category_ikea_id_by_product_id
        categories_by_ikea = Category.all.index_by(&:ikea_id)

        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        eur_rate = ExchangeRate.fetch_or_create("EUR")&.rate_per_unit
        buffer = PriceCalculationService.exchange_rate_buffer
        rate_with_buffer = (pln_rate * buffer).round(4)
        vgh_limits = europost_vgh_limits

        catalog_rows = []
        data_rows = []
        processed = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        scope = Product.select(
          :id, :sku, :name, :small_desc_name, :price, :delivery_cost, :weight,
          :package_volume, :package_dimensions, :dimensions, :dimensions_ru, :url,
          :category_id, :full_attributes
        ).order(:id)
        scope = scope.limit(limit) if limit.present? && limit.positive?

        # COUNT(*) — не COUNT(select-полей): при .select(...) иначе PG::UndefinedFunction.
        total = scope.unscope(:select).count
        Rails.logger.info("[ProductsXlsxExport] start total=#{total} limit=#{limit.inspect}")
        write_export_progress!(processed: 0, total: total, phase: "rows")
        clear_export_error!

        scope.find_each(batch_size: 300) do |product|
          ikea_id = cp_map[product.id].presence || product.category_id
          cat = categories_by_ikea[ikea_id.to_s]
          category_label = cat&.translated_name.presence || cat&.name || "Без категории"

          pricing = build_pricing_row(
            product: product,
            pln_rate: pln_rate,
            eur_rate: eur_rate,
            buffer: buffer,
            rate_with_buffer: rate_with_buffer,
            vgh_limits: vgh_limits
          )

          catalog_rows << pricing.merge(category_label: category_label)
          data_rows << pricing
          processed += 1
          if (processed % 100).zero?
            write_export_progress!(processed: processed, total: total, phase: "rows")
            Rails.logger.info("[ProductsXlsxExport] progress #{processed}/#{total}")
          end
        end

        catalog_rows.sort_by! { |r| [r[:category_label].to_s.downcase, r[:sku].to_s] }
        data_rows.sort_by! { |r| r[:sku].to_s }

        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
        write_export_progress!(processed: total, total: total, phase: "xlsx")
        Rails.logger.info("[ProductsXlsxExport] rows=#{processed} elapsed=#{elapsed}s writing xlsx")

        package = Axlsx::Package.new
        workbook = package.workbook
        styles = build_styles(workbook)

        add_catalog_worksheet(workbook, styles, catalog_rows)
        data_last_row = add_data_worksheet(workbook, styles, data_rows)
        add_calculator_worksheet(
          workbook,
          styles,
          pln_rate: pln_rate,
          buffer: buffer,
          rate_with_buffer: rate_with_buffer,
          vgh_limits: vgh_limits,
          data_last_row: data_last_row
        )

        path = export_path
        tmp_path = EXPORT_DIR.join(EXPORT_TMP_FILENAME)
        package.serialize(tmp_path.to_s)
        FileUtils.rm_f(path)
        FileUtils.mv(tmp_path, path)
        remove_stale_export_tmp_files!
        Rails.logger.info("[ProductsXlsxExport] done path=#{path} size=#{path.size} elapsed=#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}s")
        path
      rescue AlreadyBuilding
        skipped_due_to_lock = true
        raise
      rescue StandardError => e
        write_export_error!(e)
        raise
      ensure
        clear_export_progress! unless skipped_due_to_lock
        if lock_fd
          lock_fd.flock(File::LOCK_UN)
          lock_fd.close
        end
        FileUtils.rm_f(BUILD_LOCK)
      end

      def display_name_for(product)
        base = product.name.to_s.presence || product.sku.to_s
        short = product.small_desc_name.to_s.strip
        short.present? ? "#{base} (#{short})" : base
      end

      def dimensions_display_for(product)
        base = product.dimensions_ru.to_s.strip.presence || product.dimensions.to_s.strip.presence
        pkg = product.package_dimensions.to_s.strip
        return nil if base.blank? && pkg.blank?
        return base if pkg.blank? || pkg == base
        return "Упаковка: #{pkg}" if base.blank?

        "#{base}\nУпаковка: #{pkg}"
      end

      private

      def build_pricing_row(product:, pln_rate:, eur_rate:, buffer:, rate_with_buffer:, vgh_limits:)
        price_zl = product.price.to_f
        customer_payload = ProductSerializer.customer_size_payload_for_product(product)
        weight_kg = Products::WeightExtractor.extract_packaging_kg_from_customer_payload(customer_payload).to_f
        delivery_unit_pln = product.delivery_cost.to_f
        metrics = Delivery::ParcelPackingService.export_parcel_metrics(
          product,
          weight_kg: weight_kg.positive? ? weight_kg : nil,
          customer_payload: customer_payload
        )
        max_side_cm = [metrics[:width_cm], metrics[:height_cm], metrics[:depth_cm]].compact.max

        breakdown =
          if price_zl.positive?
            PriceCalculationService.line_breakdown_pln(
              unit_price_zl: price_zl,
              quantity: 1,
              weight_kg: weight_kg,
              delivery_unit_pln: delivery_unit_pln
            )
          else
            PriceCalculationService.empty_line_breakdown
          end

        byn_parts = byn_components_from_breakdown(breakdown, rate_with_buffer)

        customs_total =
          if price_zl.positive? && weight_kg.positive? && eur_rate.to_f.positive? && pln_rate.positive?
            price_eur = (price_zl * pln_rate / eur_rate).round(2)
            CustomsDutyService.calculate(price_eur, weight_kg, eur_rate)[:total_byn]
          end

        vgh = evaluate_vgh(metrics, vgh_limits)

        {
          sku: product.sku,
          display_name: display_name_for(product),
          dimensions_text: dimensions_display_for(product),
          weight_kg: weight_kg.positive? ? weight_kg : nil,
          volume_m3: metrics[:volume_m3],
          max_side_cm: max_side_cm,
          price_pln: price_zl,
          delivery_cost_pln: delivery_unit_pln,
          pricing_mode: breakdown[:mode].to_s,
          markup_k: breakdown[:markup_k],
          goods_pln: breakdown[:goods_pln],
          delivery_pln: breakdown[:delivery_pln],
          wc_by_pln: breakdown[:wc_by_pln],
          total_pln: breakdown[:total_pln],
          pln_rate: pln_rate,
          buffer: buffer,
          rate_with_buffer: rate_with_buffer,
          goods_byn: byn_parts[:goods_byn],
          delivery_to_belarus_byn: byn_parts[:delivery_to_belarus_byn],
          delivery_poland_in_price_byn: byn_parts[:delivery_poland_in_price_byn],
          price_byn: byn_parts[:total_byn],
          customs_byn: customs_total,
          vgh_weight_ok: vgh[:weight_ok] ? 1 : 0,
          vgh_volume_ok: vgh[:volume_ok] ? 1 : 0,
          vgh_dimension_ok: vgh[:dimension_ok] ? 1 : 0,
          vgh_status: vgh[:status],
          url: product.url.to_s.presence
        }
      end

      def byn_components_from_breakdown(breakdown, rate_with_buffer)
        rate = rate_with_buffer.to_f
        cheap_mult = PriceCalculationService::CHEAP_MULTIPLIER

        if breakdown[:mode] == :cheap
          goods_byn = (breakdown[:goods_pln] * cheap_mult * rate).round(2)
          delivery_to_belarus_byn = (breakdown[:wc_by_pln] * cheap_mult * rate).round(2)
          delivery_poland_in_price_byn = (breakdown[:delivery_pln] * cheap_mult * rate).round(2)
        else
          markup_k = breakdown[:markup_k].to_f
          goods_byn = (breakdown[:goods_pln] * (1 + markup_k) * rate).round(2)
          delivery_to_belarus_byn = (breakdown[:wc_by_pln] * rate).round(2)
          delivery_poland_in_price_byn = (breakdown[:delivery_pln] * rate).round(2)
        end

        total_byn = (breakdown[:total_pln] * rate).round(2)

        {
          goods_byn: goods_byn,
          delivery_to_belarus_byn: delivery_to_belarus_byn,
          delivery_poland_in_price_byn: delivery_poland_in_price_byn,
          total_byn: total_byn
        }
      end

      def europost_vgh_limits
        {
          max_weight_kg: CalculatorSetting.get("europost_max_weight_kg") || Delivery::ParcelPackingService::DEFAULT_MAX_WEIGHT_KG,
          max_volume_m3: CalculatorSetting.get("europost_max_volume_m3") || Delivery::ParcelPackingService::DEFAULT_MAX_VOLUME_M3,
          max_dimension_cm: CalculatorSetting.get("europost_max_dimension_cm") || Delivery::ParcelPackingService::DEFAULT_MAX_DIMENSION_CM
        }
      end

      def evaluate_vgh(metrics, limits)
        weight = metrics[:weight_kg].to_f
        volume = metrics[:volume_m3].to_f
        max_side = [metrics[:width_cm], metrics[:height_cm], metrics[:depth_cm]].compact.max.to_f

        issues = []
        issues << "нет веса упаковки" if weight <= 0
        issues << "вес > #{limits[:max_weight_kg]} кг" if weight.positive? && weight > limits[:max_weight_kg].to_f
        issues << "нет объёма/габаритов" if volume <= 0 && max_side <= 0
        issues << "объём > #{limits[:max_volume_m3]} м³" if volume.positive? && volume > limits[:max_volume_m3].to_f
        issues << "сторона > #{limits[:max_dimension_cm]} см" if max_side.positive? && max_side > limits[:max_dimension_cm].to_f

        weight_ok = weight.positive? && weight <= limits[:max_weight_kg].to_f
        volume_ok = volume.positive? && volume <= limits[:max_volume_m3].to_f
        dimension_ok = max_side.positive? && max_side <= limits[:max_dimension_cm].to_f

        {
          weight_ok: weight_ok,
          volume_ok: volume_ok || (volume <= 0 && max_side.positive? && dimension_ok),
          dimension_ok: dimension_ok || (max_side <= 0 && volume.positive? && volume_ok),
          status: issues.empty? ? "ВГХ в норме (Европочта)" : issues.join("; ")
        }
      end

      def build_styles(workbook)
        styles = workbook.styles
        {
          title: styles.add_style(b: true, sz: 14, fg_color: "333333", alignment: { horizontal: :left, wrap_text: true }),
          meta: styles.add_style(sz: 10, fg_color: "666666", alignment: { horizontal: :left, wrap_text: true }),
          category_band: styles.add_style(
            b: true, sz: 12, fg_color: "222222", bg_color: "E8E8E8",
            border: { style: :thin, color: "C0C0C0" }, alignment: { horizontal: :left, wrap_text: true }
          ),
          subheader: styles.add_style(
            b: true, bg_color: "F5F5F5", fg_color: "333333",
            border: { style: :thin, color: "C0C0C0" }, alignment: { horizontal: :left, wrap_text: true }
          ),
          text: styles.add_style(alignment: { horizontal: :left, vertical: :top, wrap_text: true }, border: { style: :thin, color: "D8D8D8" }),
          label: styles.add_style(b: true, alignment: { horizontal: :left, vertical: :center }),
          input: styles.add_style(
            b: true, bg_color: "FFF9E6", border: { style: :medium, color: "E6B800" },
            alignment: { horizontal: :left, vertical: :center }
          ),
          formula: styles.add_style(
            format_code: "#,##0.00", bg_color: "F0F7FF",
            border: { style: :thin, color: "A0C4E8" }, alignment: { horizontal: :right, vertical: :center }
          ),
          formula_text: styles.add_style(
            bg_color: "F0F7FF", border: { style: :thin, color: "A0C4E8" },
            alignment: { horizontal: :left, vertical: :center, wrap_text: true }
          ),
          vgh_warn: styles.add_style(
            b: true, bg_color: "FFE6E6", fg_color: "B00000",
            border: { style: :thin, color: "E08080" }, alignment: { horizontal: :left, wrap_text: true }
          ),
          vgh_ok: styles.add_style(
            bg_color: "E6F4EA", fg_color: "1B5E20",
            border: { style: :thin, color: "A5D6A7" }, alignment: { horizontal: :left, wrap_text: true }
          ),
          num: styles.add_style(
            format_code: "#,##0.00", border: { style: :thin, color: "D8D8D8" },
            alignment: { horizontal: :right, vertical: :center }
          ),
          weight: styles.add_style(
            format_code: "#,##0.###", border: { style: :thin, color: "D8D8D8" },
            alignment: { horizontal: :right, vertical: :center }
          ),
          link: styles.add_style(
            fg_color: "0563C1", u: true, border: { style: :thin, color: "D8D8D8" },
            alignment: { horizontal: :left, vertical: :top, wrap_text: true }
          ),
          catalog_data: build_zebra_data_row_styles(styles)
        }
      end

      def add_catalog_worksheet(workbook, styles, catalog_rows)
        groups = catalog_rows.slice_when { |a, b| a[:category_label] != b[:category_label] }.to_a

        workbook.add_worksheet(name: CATALOG_SHEET) do |sheet|
          excel_row = 1

          sheet.add_row(
            ["Каталог товаров по категориям (последняя связь category_products)"] + [nil] * 7,
            style: styles[:title]
          )
          sheet.merge_cells("A#{excel_row}:#{CATALOG_COL_LAST}#{excel_row}")
          excel_row += 1

          meta = "Сформировано: #{Time.zone.now.strftime('%d.%m.%Y %H:%M')} (#{Time.zone.name}) · товаров: #{catalog_rows.size}"
          sheet.add_row([meta] + [nil] * 7, style: styles[:meta])
          sheet.merge_cells("A#{excel_row}:#{CATALOG_COL_LAST}#{excel_row}")
          excel_row += 1

          sheet.add_row([])
          excel_row += 1

          groups.each_with_index do |group, group_idx|
            cat_label = group.first[:category_label]

            sheet.add_row([cat_label] + [nil] * 7, style: styles[:category_band])
            sheet.merge_cells("A#{excel_row}:#{CATALOG_COL_LAST}#{excel_row}")
            excel_row += 1

            sheet.add_row(
              ["SKU", "Название", "Размеры", "Вес (кг)", "Цена PLN", "Цена сервиса BYN", "Таможня BYN (всего)", "Ссылка на товар"],
              style: Array.new(8, styles[:subheader])
            )
            excel_row += 1

            group.each_with_index do |r, idx|
              row_styles = idx.even? ? styles[:catalog_data][:even] : styles[:catalog_data][:odd]
              sheet.add_row(
                [
                  r[:sku],
                  r[:display_name],
                  r[:dimensions_text],
                  r[:weight_kg].present? && r[:weight_kg].to_f.positive? ? r[:weight_kg].to_f : nil,
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

          sheet.column_widths 14, 48, 34, 14, 14, 28, 26, 80
        end
      end

      def add_data_worksheet(workbook, styles, data_rows)
        last_row = data_rows.empty? ? DATA_FIRST_ROW : (DATA_FIRST_ROW + data_rows.size - 1)

        workbook.add_worksheet(name: DATA_SHEET) do |sheet|
          sheet.add_row(
            ["Плоская таблица для листа «Калькулятор». Строки соответствуют товарам с листа «Товары»."] + [nil] * (DATA_HEADERS.size - 1),
            style: styles[:meta]
          )
          sheet.merge_cells("A1:#{data_col_letter(DATA_HEADERS.size)}1")

          sheet.add_row(DATA_HEADERS, style: Array.new(DATA_HEADERS.size, styles[:subheader]))

          row_styles = build_data_row_styles(styles)
          sku_types = [:string] + [nil] * (DATA_HEADERS.size - 1)
          data_rows.each do |r|
            sheet.add_row(
              [
                r[:sku].to_s,
                r[:display_name],
                r[:dimensions_text],
                r[:weight_kg],
                r[:volume_m3],
                r[:max_side_cm],
                r[:price_pln].positive? ? r[:price_pln] : nil,
                r[:delivery_cost_pln],
                r[:pricing_mode],
                r[:markup_k],
                r[:goods_pln],
                r[:delivery_pln],
                r[:wc_by_pln],
                r[:total_pln],
                r[:pln_rate],
                r[:buffer],
                r[:rate_with_buffer],
                r[:goods_byn].positive? ? r[:goods_byn] : nil,
                r[:delivery_to_belarus_byn].positive? ? r[:delivery_to_belarus_byn] : nil,
                r[:delivery_poland_in_price_byn].positive? ? r[:delivery_poland_in_price_byn] : nil,
                r[:price_byn].positive? ? r[:price_byn] : nil,
                r[:customs_byn],
                r[:vgh_weight_ok],
                r[:vgh_volume_ok],
                r[:vgh_dimension_ok],
                r[:vgh_status]
              ],
              style: row_styles,
              types: sku_types
            )
          end

          sheet.column_widths 14, 40, 32, 12, 12, 12, 12, 12, 10, 10, 12, 14, 14, 12, 12, 10, 12, 14, 16, 14, 14, 12, 8, 8, 8, 36
        end

        last_row
      end

      def add_calculator_worksheet(workbook, styles, pln_rate:, buffer:, rate_with_buffer:, vgh_limits:, data_last_row:)
        cheap_threshold = PriceCalculationService.cheap_threshold_pln
        sku_ref = nil
        vgh_warn_dxf = workbook.styles.add_style(bg_color: "FFE6E6", fg_color: "B00000", type: :dxf)

        workbook.add_worksheet(name: CALC_SHEET, escape_formulas: false) do |sheet|
          sheet.add_row(["Калькулятор цены по SKU"], style: styles[:title])
          sheet.add_row([])

          logic_lines.each do |line|
            sheet.add_row([line], style: styles[:text])
          end

          sheet.add_row([])
          sheet.add_row(["Параметры на момент выгрузки"], style: styles[:label])
          sheet.add_row(["Курс PLN (НБ РБ)", pln_rate], style: [styles[:label], styles[:num]])
          sheet.add_row(["Буфер курса", buffer], style: [styles[:label], styles[:num]])
          sheet.add_row(["Курс × буфер", rate_with_buffer], style: [styles[:label], styles[:num]])
          sheet.add_row(["Порог cheap (PLN)", cheap_threshold], style: [styles[:label], styles[:num]])
          sheet.add_row(["Лимит веса Европочты (кг)", vgh_limits[:max_weight_kg]], style: [styles[:label], styles[:num]])
          sheet.add_row(["Лимит объёма (м³)", vgh_limits[:max_volume_m3]], style: [styles[:label], styles[:num]])
          sheet.add_row(["Лимит стороны (см)", vgh_limits[:max_dimension_cm]], style: [styles[:label], styles[:num]])

          sheet.add_row([])
          sheet.add_row(["→ Введите SKU", ""], style: [styles[:label], styles[:input]], types: [nil, :string])
          sku_ref = "B#{sheet.rows.size}"

          sheet.add_row([])
          sheet.add_row(["Результат (поиск на листе «Данные»)"], style: styles[:label])

          add_formula_row(sheet, styles, "Название", lookup_formula(sku_ref, data_last_row, col: 2), text: true)
          add_formula_row(sheet, styles, "Размеры / упаковка", lookup_formula(sku_ref, data_last_row, col: 3), text: true)
          add_formula_row(sheet, styles, "Цена товара (BYN)", lookup_formula(sku_ref, data_last_row, col: 18))
          add_formula_row(sheet, styles, "Доставка до Беларуси (BYN)", lookup_formula(sku_ref, data_last_row, col: 19))
          add_formula_row(sheet, styles, "Доставка PL в цене (BYN)", lookup_formula(sku_ref, data_last_row, col: 20))
          add_formula_row(sheet, styles, "Цена сервиса (BYN)", lookup_formula(sku_ref, data_last_row, col: 21))
          add_formula_row(sheet, styles, "Таможенный платёж (BYN)", lookup_formula(sku_ref, data_last_row, col: 22))
          add_formula_row(sheet, styles, "Режим цены (cheap/k)", lookup_formula(sku_ref, data_last_row, col: 9), text: true)
          add_formula_row(sheet, styles, "Цена IKEA (PLN)", lookup_formula(sku_ref, data_last_row, col: 7))
          add_formula_row(sheet, styles, "WC_BY (PLN)", lookup_formula(sku_ref, data_last_row, col: 13))

          sheet.add_row([])
          sheet.add_row(["ВГХ (подсветка при превышении лимита)"], style: styles[:label])

          [
            ["Вес упаковки (кг)", 4, vgh_limits[:max_weight_kg], "кг"],
            ["Объём (м³)", 5, vgh_limits[:max_volume_m3], "м³"],
            ["Макс. сторона (см)", 6, vgh_limits[:max_dimension_cm], "см"]
          ].each do |label, col, limit, unit|
            formula = lookup_formula(sku_ref, data_last_row, col: col)
            row = sheet.add_row([label], style: [styles[:label]])
            row.add_cell(formula, escape_formulas: false, style: styles[:formula])
            row.add_cell("лимит", style: styles[:label])
            row.add_cell(limit, style: styles[:num])
            row.add_cell(unit, style: styles[:text])
            row_idx = sheet.rows.size
            sheet.add_conditional_formatting(
              "B#{row_idx}",
              type: :cellIs,
              operator: :greaterThan,
              formula: "D#{row_idx}",
              dxfId: vgh_warn_dxf,
              priority: 1
            )
          end

          add_formula_row(
            sheet, styles, "Статус ВГХ",
            lookup_formula(sku_ref, data_last_row, col: 26),
            text: true,
            value_style: styles[:vgh_ok]
          )

          sheet.add_row([])
          sheet.add_row(
            ["Подсказка", "SKU в #{sku_ref}. Таблица — лист «Данные», строки #{DATA_FIRST_ROW}–#{data_last_row} (как в «Товары»)."],
            style: [styles[:label], styles[:text]]
          )

          sheet.column_widths 30, 24, 10, 14, 8
        end
      end

      def add_formula_row(sheet, styles, label, formula, text: false, value_style: nil)
        row = sheet.add_row([label], style: [styles[:label]])
        row.add_cell(formula, escape_formulas: false, style: value_style || styles[:formula])
      end

      def logic_lines
        [
          "Логика совпадает с PriceCalculationService (карточка товара и корзина).",
          "1) Цена IKEA в PLN + delivery_cost (PLN/шт) + логистика по РБ WC_BY = вес × ставка PLN/кг (belarus_delivery_rates).",
          "2) Режим cheap: если цена IKEA ≤ порога PLN — итог PLN = (товар + delivery_cost + WC_BY) × 1.3.",
          "3) Режим k: иначе товар с наценкой K = max(10%, 87/цена − 0.187), итог = товар×(1+K) + delivery_cost + WC_BY.",
          "4) Перевод в BYN: итог PLN × курс PLN→BYN × буфер (по умолчанию 1.05).",
          "5) Таможня: отдельно по стоимости в EUR и весу (CustomsDutyService), в цену сервиса не входит.",
          "6) ВГХ: вес/объём/сторона из упаковки товара; лимиты — настройки europost_max_* (доступность ПВЗ).",
          "Лист «Данные» — плоская копия расчётных полей; калькулятор ищет SKU через INDEX/MATCH."
        ]
      end

      def lookup_formula(sku_cell, data_last_row, col:, text: false)
        lookup_range, return_range = data_sheet_lookup_ranges(data_last_row, col)
        sku_key = "TEXT(TRIM(#{sku_cell}),\"0\")"
        text # reserved
        "=IF(#{sku_key}=\"\",\"введите SKU\",IFERROR(INDEX(#{return_range},MATCH(#{sku_key},#{lookup_range},0)),\"не найден\"))"
      end

      def data_sheet_lookup_ranges(data_last_row, col)
        first = DATA_FIRST_ROW
        lookup = "'#{DATA_SHEET}'!$A$#{first}:$A$#{data_last_row}"
        return_col = data_col_letter(col)
        returns = "'#{DATA_SHEET}'!$#{return_col}$#{first}:$#{return_col}$#{data_last_row}"
        [lookup, returns]
      end

      def data_col_letter(index)
        Axlsx.col_ref(index - 1)
      end

      def build_data_row_styles(styles)
        [
          styles[:text],
          styles[:text],
          styles[:text],
          styles[:weight],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:text],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:num],
          styles[:text]
        ]
      end

      def build_zebra_data_row_styles(styles)
        mk = lambda do |bg|
          [
            styles.add_style(border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :left }),
            styles.add_style(border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :left, wrap_text: true }),
            styles.add_style(border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :left, wrap_text: true }),
            styles.add_style(format_code: "#,##0.###", border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :right }),
            styles.add_style(format_code: "#,##0.00", border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :right }),
            styles.add_style(format_code: "#,##0.00", border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :right }),
            styles.add_style(format_code: "#,##0.00", border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :right }),
            styles.add_style(fg_color: "0563C1", u: true, border: { style: :thin, color: "D8D8D8" }, bg_color: bg, alignment: { horizontal: :left, wrap_text: true })
          ]
        end

        { even: mk.call("FFFFFF"), odd: mk.call("FAFAFA") }
      end

      def remove_stale_export_tmp_files!
        Dir.glob(EXPORT_DIR.join("*.xlsx.tmp")).each { |f| FileUtils.rm_f(f) }
      end

      def write_export_progress!(processed:, total:, phase:)
        FileUtils.mkdir_p(EXPORT_DIR)
        PROGRESS_FILE.write(
          {
            processed: processed,
            total: total,
            phase: phase,
            at: Time.zone.now.iso8601
          }.to_json
        )
      end

      def clear_export_progress!
        FileUtils.rm_f(PROGRESS_FILE)
      end

      def write_export_error!(error)
        FileUtils.mkdir_p(EXPORT_DIR)
        LAST_ERROR_FILE.write("#{error.class}: #{error.message}\n")
      end

      def clear_export_error!
        FileUtils.rm_f(LAST_ERROR_FILE)
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
