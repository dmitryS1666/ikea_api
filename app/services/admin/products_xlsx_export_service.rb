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
    SUMMARY_SHEET = "Сводка"
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

    # Колонки для find_each: хватает памяти на полный каталог, но должны
    # покрывать unit_breakdown (в т.ч. price_addon_pln) и ВГХ из упаковки.
    EXPORT_PRODUCT_COLUMNS = [
      :id, :sku, :name, :small_desc_name, :price, :price_addon_pln, :delivery_cost, :weight,
      :package_volume, :package_dimensions, :dimensions, :dimensions_ru, :url,
      :category_id, :full_attributes
    ].freeze

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

        scope = Product.select(*EXPORT_PRODUCT_COLUMNS).order(:id)
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

        add_summary_worksheet(
          workbook,
          styles,
          catalog_rows: catalog_rows,
          pln_rate: pln_rate,
          eur_rate: eur_rate,
          buffer: buffer,
          rate_with_buffer: rate_with_buffer,
          vgh_limits: vgh_limits
        )
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
        customer_payload = ProductSerializer.customer_size_payload_for_product(product)
        weight_kg = Products::WeightExtractor.extract_packaging_kg_from_customer_payload(customer_payload)
        metrics = Delivery::ParcelPackingService.export_parcel_metrics(
          product,
          weight_kg: weight_kg,
          customer_payload: customer_payload
        )
        max_side_cm = [metrics[:width_cm], metrics[:height_cm], metrics[:depth_cm]].compact.max
        unit = PriceCalculationService.unit_breakdown(
          ikea_price_pln: product.price,
          price_addon_pln: product.price_addon_pln,
          weight_kg: weight_kg,
          d_ikea_pln: product.delivery_cost,
          pln_rate: pln_rate,
          eur_rate: eur_rate,
          buffer: buffer
        )
        vgh = evaluate_vgh(metrics, vgh_limits)
        rate = Pricing::Money.bd(rate_with_buffer) || BigDecimal("0")

        {
          sku: product.sku,
          display_name: display_name_for(product),
          dimensions_text: dimensions_display_for(product),
          weight_kg: weight_kg,
          volume_m3: metrics[:volume_m3],
          max_side_cm: max_side_cm,
          price_pln: product.price.to_f,
          delivery_cost_pln: product.delivery_cost,
          pricing_mode: unit[:pricing_mode].to_s,
          markup_k: unit[:markup_rate]&.to_f,
          goods_pln: Pricing::Money.to_f_round2(unit[:goods_pln]),
          delivery_pln: Pricing::Money.to_f_round2(unit[:d_ikea_pln]),
          wc_by_pln: Pricing::Money.to_f_round2(unit[:wc_pln]),
          total_pln: Pricing::Money.to_f_round2(unit[:subtotal_pln]),
          pln_rate: pln_rate,
          buffer: buffer,
          rate_with_buffer: rate_with_buffer,
          goods_byn: unit[:pricing_available] ? Pricing::Money.to_f_round2(unit[:goods_pln] * rate) : nil,
          delivery_to_belarus_byn: unit[:pricing_available] ? Pricing::Money.to_f_round2(unit[:wc_pln] * rate) : nil,
          delivery_poland_in_price_byn: unit[:pricing_available] ? Pricing::Money.to_f_round2(unit[:d_ikea_pln] * rate) : nil,
          price_byn: unit[:pricing_available] ? Pricing::Money.to_f_round2(unit[:card_price_byn]) : nil,
          customs_byn: unit[:pricing_available] ? Pricing::Money.to_f_round2(unit[:customs_total_byn]) : nil,
          vgh_weight_ok: vgh[:weight_ok] ? 1 : 0,
          vgh_volume_ok: vgh[:volume_ok] ? 1 : 0,
          vgh_dimension_ok: vgh[:dimension_ok] ? 1 : 0,
          vgh_status: vgh[:status],
          url: product.url.to_s.presence,
          pricing_available: unit[:pricing_available]
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

      def add_summary_worksheet(workbook, styles, catalog_rows:, pln_rate:, eur_rate:, buffer:, rate_with_buffer:, vgh_limits:)
        snapshot = formula_snapshot
        priced = catalog_rows.count { |row| row[:pricing_available] }
        unclear = catalog_rows.size - priced

        workbook.add_worksheet(name: SUMMARY_SHEET) do |sheet|
          sheet.add_row(["Сводка коэффициентов на момент выгрузки"], style: styles[:title])
          sheet.add_row(
            ["Сформировано: #{Time.zone.now.strftime('%d.%m.%Y %H:%M')} (#{Time.zone.name})"],
            style: styles[:meta]
          )
          sheet.add_row(
            ["Товаров в файле: #{catalog_rows.size} · цена посчитана: #{priced} · «Цена уточняется»: #{unclear}"],
            style: styles[:meta]
          )
          sheet.add_row([])

          if snapshot[:error]
            sheet.add_row(["Не удалось прочитать настройки", snapshot[:error]], style: [styles[:label], styles[:vgh_warn]])
          else
            sheet.add_row(["Формула карточки"], style: styles[:label])
            formula_lines(snapshot).each { |line| sheet.add_row([line], style: styles[:text]) }
            sheet.add_row([])

            sheet.add_row(["Курсы"], style: styles[:label])
            add_kv_row(sheet, styles, "Курс PLN (НБ РБ)", pln_rate, numeric: true)
            add_kv_row(sheet, styles, "Курс EUR (НБ РБ)", eur_rate, numeric: true)
            add_kv_row(sheet, styles, "Буфер курса", buffer, numeric: true)
            add_kv_row(sheet, styles, "Курс PLN × буфер", rate_with_buffer, numeric: true)
            add_kv_row(sheet, styles, "VAT Польша", snapshot[:vat_multiplier], numeric: true)
            sheet.add_row([])

            sheet.add_row(["Наценка (goods / P)"], style: styles[:label])
            add_kv_row(sheet, styles, "Порог cheap, PLN", snapshot[:cheap_threshold_pln], numeric: true)
            add_kv_row(sheet, styles, "Множитель cheap", snapshot[:cheap_multiplier], numeric: true)
            add_kv_row(sheet, styles, "Целевая прибыль, PLN", snapshot[:target_profit_pln], numeric: true)
            add_kv_row(sheet, styles, "Вычитаемое K", snapshot[:markup_subtrahend], numeric: true)
            add_kv_row(sheet, styles, "Минимальная наценка K", snapshot[:min_markup], numeric: true)
            sheet.add_row(["K = max(мин. наценка, целевая прибыль / P − вычитаемое). Только на P, не на D_IKEA и не на WC."], style: styles[:text])
            sheet.add_row([])

            sheet.add_row(["Таможня"], style: styles[:label])
            add_kv_row(sheet, styles, "Беспошлинный лимит C, EUR", snapshot[:customs_free_cost_limit], numeric: true)
            add_kv_row(sheet, styles, "Беспошлинный вес, кг", snapshot[:customs_free_weight_limit], numeric: true)
            add_kv_row(sheet, styles, "Ставка от превышения C", snapshot[:customs_cost_duty_rate], numeric: true)
            add_kv_row(sheet, styles, "Ставка от превышения веса, EUR/кг", snapshot[:customs_weight_duty_rate], numeric: true)
            add_kv_row(sheet, styles, "Сбор, BYN (один раз, если duty > 0)", snapshot[:customs_fee], numeric: true)
            sheet.add_row(["C = (IKEA / VAT) × PLN_EUR. Без буфера, addon, D_IKEA и WC. На карточке таможня входит в цену только если одна единица уже выше лимита."], style: styles[:text])
            sheet.add_row([])

            sheet.add_row(["WC Беларусь, PLN/кг (не прогрессивно, вес одной единицы)"], style: styles[:label])
            sheet.add_row(["Диапазон веса, кг", "Ставка, PLN/кг"], style: [styles[:subheader], styles[:subheader]])
            wc_rate_rows(snapshot[:belarus_delivery_rates]).each do |band, rate|
              sheet.add_row([band, rate], style: [styles[:text], styles[:num]])
            end
            sheet.add_row([])

            dest = snapshot.dig(:ikea_delivery_config, "destination") || {}
            sheet.add_row(["D_IKEA — тарифы IKEA.pl"], style: styles[:label])
            sheet.add_row(["Назначение", [dest["city"], dest["postal_code"], dest["address"]].compact.join(", ").presence || "—"], style: [styles[:label], styles[:text]])
            sheet.add_row(["Источник", snapshot.dig(:ikea_delivery_config, "source") || "ikea_delivery_config"], style: [styles[:label], styles[:text]])
            sheet.add_row(["IKEA Family", snapshot.dig(:ikea_delivery_config, "use_member_prices") ? "да" : "нет"], style: [styles[:label], styles[:text]])
            sheet.add_row(
              ["Код", "Название", "PLN", "Вес, кг", "Только GLS-коробка", "Вкл."],
              style: Array.new(6, styles[:subheader])
            )
            ikea_method_rows(snapshot[:ikea_delivery_config]).each do |method_row|
              sheet.add_row(method_row, style: [styles[:text], styles[:text], styles[:num], styles[:text], styles[:text], styles[:text]])
            end
            sheet.add_row(["GLS берётся только если все коробки с габаритами проходят лимиты; иначе transport по весу."], style: styles[:text])
            sheet.add_row([])
          end

          sheet.add_row(["ВГХ Европочты (доступность ПВЗ, не цена карточки)"], style: styles[:label])
          add_kv_row(sheet, styles, "Лимит веса, кг", vgh_limits[:max_weight_kg], numeric: true)
          add_kv_row(sheet, styles, "Лимит объёма, м³", vgh_limits[:max_volume_m3], numeric: true)
          add_kv_row(sheet, styles, "Лимит стороны, см", vgh_limits[:max_dimension_cm], numeric: true)

          sheet.column_widths 42, 36, 12, 16, 20, 10
        end
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
                  positive_cell(r[:price_pln]),
                  positive_cell(r[:price_byn]),
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
                positive_cell(r[:price_pln]),
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
                positive_cell(r[:goods_byn]),
                positive_cell(r[:delivery_to_belarus_byn]),
                positive_cell(r[:delivery_poland_in_price_byn]),
                positive_cell(r[:price_byn]),
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
          sheet.add_row(["Полный набор коэффициентов — лист «Сводка»."], style: styles[:text])
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
        snapshot = formula_snapshot
        return ["Логика совпадает с PriceCalculationService (карточка товара)."] if snapshot[:error]

        formula_lines(snapshot) + [
          "Лист «Данные» — плоская копия расчётных полей; калькулятор ищет SKU через INDEX/MATCH.",
          "Коэффициенты и тарифы D_IKEA/WC — лист «Сводка»."
        ]
      end

      def formula_lines(snapshot)
        cheap = snapshot[:cheap_multiplier]
        threshold = snapshot[:cheap_threshold_pln]
        min_k = snapshot[:min_markup]
        target = snapshot[:target_profit_pln]
        sub = snapshot[:markup_subtrahend]
        buffer = snapshot[:exchange_rate_buffer]
        vat = snapshot[:vat_multiplier]
        c_lim = snapshot[:customs_free_cost_limit]
        w_lim = snapshot[:customs_free_weight_limit]

        [
          "Логика совпадает с витриной (PriceCalculationService).",
          "P = IKEA + max(0, price_addon_pln).",
          "cheap: P ≤ #{format_coeff(threshold)} PLN → goods = P × #{format_coeff(cheap)}. Только на P, не на D_IKEA и не на WC.",
          "k: goods = P × (1 + max(#{format_coeff(min_k)}, #{format_coeff(target)} / P − #{format_coeff(sub)})).",
          "Цена сервиса BYN = (goods + D_IKEA + WC) × курс PLN × #{format_coeff(buffer)}, плюс таможня если одна единица C > #{format_coeff(c_lim)} € или W > #{format_coeff(w_lim)} кг.",
          "Таможенная база C = (IKEA / #{format_coeff(vat)}) × PLN_EUR без буфера и без addon."
        ]
      end

      def formula_snapshot
        {
          cheap_threshold_pln: Pricing::Settings.cheap_threshold_pln.to_f,
          cheap_multiplier: Pricing::Settings.cheap_multiplier.to_f,
          target_profit_pln: Pricing::Settings.target_profit_pln.to_f,
          markup_subtrahend: Pricing::Settings.markup_subtrahend.to_f,
          min_markup: Pricing::Settings.min_markup.to_f,
          exchange_rate_buffer: Pricing::Settings.exchange_rate_buffer.to_f,
          vat_multiplier: Pricing::Settings.vat_multiplier.to_f,
          customs_free_cost_limit: Pricing::Settings.customs_free_cost_limit.to_f,
          customs_free_weight_limit: Pricing::Settings.customs_free_weight_limit.to_f,
          customs_cost_duty_rate: Pricing::Settings.customs_cost_duty_rate.to_f,
          customs_weight_duty_rate: Pricing::Settings.customs_weight_duty_rate.to_f,
          customs_fee: Pricing::Settings.customs_fee.to_f,
          belarus_delivery_rates: Pricing::Settings.belarus_delivery_rates,
          ikea_delivery_config: Pricing::Settings.ikea_delivery_config
        }
      rescue Pricing::ConfigurationError => e
        { error: e.message }
      end

      def wc_rate_rows(rates)
        hash = rates.is_a?(Hash) ? rates : {}
        hash.map { |band, rate| [band.to_s, rate.to_f] }.sort_by { |band, _rate| band[/\d+(?:\.\d+)?/].to_f }
      end

      def ikea_method_rows(config)
        methods = Array(config.is_a?(Hash) ? (config["methods"] || config[:methods]) : nil)
        methods.map do |method|
          next unless method.is_a?(Hash)

          min_w = method["min_weight_kg"] || method.dig("constraints", "min_weight_kg")
          max_w = method["max_weight_kg"] || method.dig("constraints", "max_weight_kg")
          cost = method["cost_pln"] || method["price_pln"]
          enabled = ActiveModel::Type::Boolean.new.cast(method["enabled"])
          gls_only = ActiveModel::Type::Boolean.new.cast(method["requires_product_eligibility"])
          [
            method["code"].to_s,
            method["name"].to_s,
            cost&.to_f,
            [min_w, max_w].compact.join("–"),
            gls_only ? "да" : "нет",
            enabled ? "да" : "нет"
          ]
        end.compact
      end

      def add_kv_row(sheet, styles, label, value, numeric: false)
        sheet.add_row([label, value], style: [styles[:label], numeric ? styles[:num] : styles[:text]])
      end

      def format_coeff(value)
        number = value.to_f
        number == number.to_i ? number.to_i.to_s : number.to_s
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

      def positive_cell(value)
        value.is_a?(Numeric) && value.positive? ? value : nil
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
