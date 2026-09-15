# frozen_string_literal: true

module Admin
  class PriceCalculatorService
    LineParseResult = Struct.new(:lines, :errors, keyword_init: true)

    class << self
      def find_product(sku)
        raw = sku.to_s.strip
        return nil if raw.blank?

        Products::ListingSkuResolver.find_product(raw) ||
          Product.find_by(sku: raw) ||
          Product.find_by(item_no: raw.gsub(/\D/, ""))
      end

      def parse_cart_lines(text)
        errors = []
        lines = []

        text.to_s.split(/\r?\n/).each_with_index do |raw_line, idx|
          line = raw_line.strip
          next if line.blank?
          next if line.start_with?("#")

          sku_part, qty_part =
            if line.include?(":")
              line.split(":", 2)
            elsif line.match?(/\s+/)
              line.split(/\s+/, 2)
            else
              [line, "1"]
            end

          sku = Products::ListingSkuResolver.coerce_listing_identifier(sku_part.to_s.strip)
          if sku.blank?
            errors << "Строка #{idx + 1}: не удалось распознать SKU"
            next
          end

          qty = qty_part.to_s.strip.presence&.to_i || 1
          if qty <= 0
            errors << "Строка #{idx + 1}: количество должно быть > 0"
            next
          end

          product = find_product(sku)
          unless product
            errors << "Строка #{idx + 1}: товар #{sku} не найден в БД"
            next
          end

          lines << { sku: product.sku.to_s, quantity: qty, product: product }
        end

        LineParseResult.new(lines: lines, errors: errors)
      end

      def build_virtual_cart(line_entries)
        cart = Cart.new
        line_entries.each do |entry|
          product = entry[:product]
          cart.cart_items.build(
            product_sku: product.sku.to_s,
            quantity: entry[:quantity].to_i,
            product: product
          )
        end
        cart
      end

      def calculate_cart(line_entries, date: Date.current)
        return { error: "Добавьте хотя бы одну позицию" } if line_entries.blank?

        cart = build_virtual_cart(line_entries)
        pricing = CartPricingService.call(cart: cart)
        totals = CartDisplayTotalsService.for_summary(pricing[:totals])
        delivery_options = DeliveryOptionsService.call(cart)

        {
          items: pricing[:items].map { |row| format_pricing_item(row) },
          totals: totals,
          delivery: {
            total_weight_kg: totals[:total_weight_kg].to_f,
            delivery_poland_byn: totals[:delivery_poland_byn].to_f,
            delivery_to_belarus_byn: totals[:delivery_to_belarus_byn].to_f,
            delivery_total_byn: totals[:delivery_total_byn].to_f,
            europost_eligible: delivery_options.dig(:cart_vgh, :eligible_for_europost),
            ineligible_reason: delivery_options.dig(:cart_vgh, :ineligible_reason),
            parcels_count: delivery_options.dig(:parcel_summary, :parcels_count)
          },
          meta: pricing[:meta],
          date: date
        }
      end

      def calculate_sku(product, quantity:, use_gls_pickup: false, delivery_pln: nil, date: Date.current, price_addon_pln: nil)
        qty = quantity.to_i
        qty = 1 if qty <= 0

        unit_price = product.price
        return { error: "У товара не задана цена (PLN)" } if unit_price.nil? || unit_price.to_f <= 0

        weight_kg = product.packaging_weight_kg
        return { error: "Не удалось определить вес упаковки (packaging_weight_kg)" } if weight_kg.nil? || weight_kg.to_f <= 0

        delivery_unit =
          if !delivery_pln.nil?
            delivery_pln
          else
            product.delivery_cost
          end

        if delivery_unit.nil?
          delivery_unit = PolandDeliveryService.calculate(weight_kg, use_gls_pickup: use_gls_pickup)
        end

        addon = price_addon_pln.nil? ? product.price_addon_pln : price_addon_pln
        pln_rate = ExchangeRate.fetch_or_create("PLN", date)&.rate_per_unit
        eur_rate = ExchangeRate.fetch_or_create("EUR", date)&.rate_per_unit
        return { error: "Не удалось получить курсы валют на #{date}" } unless pln_rate && eur_rate

        unit = PriceCalculationService.unit_breakdown(
          ikea_price_pln: unit_price,
          price_addon_pln: addon,
          weight_kg: weight_kg,
          d_ikea_pln: delivery_unit,
          pln_rate: pln_rate,
          eur_rate: eur_rate
        )
        return { error: "Цена уточняется: #{Array(unit[:pricing_errors]).join(", ")}" } unless unit[:pricing_available]

        byn = PriceCalculationService.line_byn_components(
          unit_price_zl: unit_price,
          quantity: qty,
          weight_kg: weight_kg,
          delivery_unit_pln: delivery_unit,
          pln_rate: pln_rate,
          buffer: unit[:exchange_rate_buffer],
          date: date,
          price_addon_pln: addon,
          eur_rate: eur_rate
        )
        cart_c = PriceCalculationService.customs_cost_eur(unit_price, pln_rate: pln_rate, eur_rate: eur_rate) * qty
        customs = CustomsDutyService.calculate(cart_c, weight_kg * qty, eur_rate)

        {
          product: product_snapshot(product),
          quantity: qty,
          unit_weight_kg: weight_kg,
          line_weight_kg: (weight_kg * qty),
          delivery_unit_pln: delivery_unit,
          unit: unit,
          breakdown: PriceCalculationService.line_breakdown_pln(
            unit_price_zl: unit_price,
            quantity: qty,
            weight_kg: weight_kg,
            delivery_unit_pln: delivery_unit,
            price_addon_pln: addon
          ),
          byn: byn,
          pln_rate: pln_rate,
          eur_rate: eur_rate,
          buffer: unit[:exchange_rate_buffer].to_f,
          customs: customs,
          date: date
        }
      end

      private

      def product_snapshot(product)
        {
          sku: product.sku.to_s,
          name: product.name_ru.presence || product.name.presence || product.small_desc_name,
          price_pln: product.price.to_f,
          price_addon_pln: product.price_addon_pln.to_f,
          delivery_cost_pln: product.delivery_cost,
          packaging_weight_kg: product.packaging_weight_kg,
          category_id: product.category_id
        }
      end

      def format_pricing_item(row)
        {
          sku: row[:sku],
          quantity: row[:quantity],
          unit_price_pln: row[:unit_price_pln],
          unit_price_byn: row[:unit_price_byn],
          unit_price_byn_checkout: row[:unit_price_byn_checkout],
          line_total_byn: row[:line_total_byn],
          line_total_byn_checkout: row[:line_total_byn_checkout],
          line_total_pln: row[:line_total_pln],
          pricing_mode: row[:pricing_mode],
          promo_applied: row[:promo_applied],
          weight: row[:weight],
          pricing_available: row[:pricing_available]
        }
      end
    end
  end
end
