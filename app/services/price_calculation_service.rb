# frozen_string_literal: true

class PriceCalculationService
  CUSTOMS_NOTICE = "Таможенный сбор рассчитывается в корзине, если заказ дороже 200 € или тяжелее 31 кг"

  class << self
    def cheap_threshold_pln
      Pricing::Settings.cheap_threshold_pln.to_f
    end

    def cheap_multiplier
      Pricing::Settings.cheap_multiplier.to_f
    end

    def exchange_rate_buffer
      Pricing::Settings.exchange_rate_buffer.to_f
    end

    def vat_multiplier
      Pricing::Settings.vat_multiplier.to_f
    end

    def compute_k(price_zl)
      p = Pricing::Money.bd(price_zl)
      return Pricing::Settings.min_markup if p.nil? || p <= 0

      k = (Pricing::Settings.target_profit_pln / p) - Pricing::Settings.markup_subtrahend
      [k, Pricing::Settings.min_markup].max
    end

    def pricing_mode_for(price_zl)
      p = Pricing::Money.bd(price_zl)
      return :cheap if p.nil? || p <= 0

      p <= Pricing::Settings.cheap_threshold_pln ? :cheap : :k
    end

    def effective_p_pln(ikea_price_pln, price_addon_pln = 0)
      ikea = Pricing::Money.bd(ikea_price_pln) || BigDecimal("0")
      addon = [Pricing::Money.bd(price_addon_pln) || BigDecimal("0"), BigDecimal("0")].max
      ikea + addon
    end

    def customs_cost_eur(ikea_price_pln, pln_rate:, eur_rate:)
      ikea = Pricing::Money.bd(ikea_price_pln)
      pln = Pricing::Money.bd(pln_rate)
      eur = Pricing::Money.bd(eur_rate)
      return nil if ikea.nil? || pln.nil? || eur.nil? || eur <= 0 || ikea < 0

      (ikea / Pricing::Settings.vat_multiplier) * (pln / eur)
    end

    def unit_breakdown(ikea_price_pln:, price_addon_pln: 0, weight_kg:, d_ikea_pln:, pln_rate:, eur_rate:, buffer: nil)
      errors = []
      ikea = Pricing::Money.bd(ikea_price_pln)
      errors << "missing_ikea_price" if ikea.nil? || ikea <= 0
      errors << "missing_weight" if weight_kg.nil? || Pricing::Money.bd(weight_kg).nil? || Pricing::Money.bd(weight_kg) <= 0
      errors << "missing_ikea_delivery" if d_ikea_pln.nil?
      errors << "missing_exchange_rate" if Pricing::Money.bd(pln_rate).nil? || Pricing::Money.bd(pln_rate) <= 0

      addon = [Pricing::Money.bd(price_addon_pln) || BigDecimal("0"), BigDecimal("0")].max
      p = (ikea || BigDecimal("0")) + addon
      buffer_bd = Pricing::Money.bd(buffer) || Pricing::Settings.exchange_rate_buffer
      pln_bd = Pricing::Money.bd(pln_rate)
      eur_bd = Pricing::Money.bd(eur_rate)
      weight = Pricing::Money.bd(weight_kg)
      d_ikea = Pricing::Money.bd(d_ikea_pln)

      if errors.any?
        return unavailable_unit(
          ikea_price_pln: ikea,
          price_addon_pln: addon,
          effective_price_p_pln: p,
          weight_kg: weight,
          d_ikea_pln: d_ikea,
          pln_byn_raw: pln_bd,
          exchange_rate_buffer: buffer_bd,
          errors: errors
        )
      end

      mode = pricing_mode_for(p)
      markup_rate = mode == :cheap ? (Pricing::Settings.cheap_multiplier - 1) : compute_k(p)
      goods = mode == :cheap ? (p * Pricing::Settings.cheap_multiplier) : (p * (1 + markup_rate))

      wc = BelarusDeliveryService.quote(weight)
      if wc.nil?
        return unavailable_unit(
          ikea_price_pln: ikea,
          price_addon_pln: addon,
          effective_price_p_pln: p,
          weight_kg: weight,
          d_ikea_pln: d_ikea,
          pln_byn_raw: pln_bd,
          exchange_rate_buffer: buffer_bd,
          errors: ["missing_weight"]
        )
      end

      subtotal_pln = goods + d_ikea + wc[:amount_pln]
      base_price_byn = Pricing::Money.round2(subtotal_pln * pln_bd * buffer_bd)

      c_eur = customs_cost_eur(ikea, pln_rate: pln_bd, eur_rate: eur_bd)
      customs = if c_eur && eur_bd && eur_bd.positive?
                  CustomsDutyService.calculate(c_eur, weight, eur_bd)
                else
                  zero_customs
                end

      threshold_exceeded = customs[:total_byn].to_f.positive?
      customs_total = Pricing::Money.bd(customs[:total_byn]) || BigDecimal("0")
      card_price = threshold_exceeded ? Pricing::Money.round2(base_price_byn + customs_total) : base_price_byn

      {
        ikea_price_pln: ikea,
        price_addon_pln: addon,
        effective_price_p_pln: p,
        pricing_mode: mode,
        markup_rate: markup_rate,
        goods_pln: goods,
        weight_kg: weight,
        wc_rate: wc[:rate],
        wc_pln: wc[:amount_pln],
        d_ikea_pln: d_ikea,
        subtotal_pln: subtotal_pln,
        pln_byn_raw: pln_bd,
        exchange_rate_buffer: buffer_bd,
        base_price_byn: base_price_byn,
        customs_cost_eur: c_eur,
        customs_duty_byn: Pricing::Money.bd(customs[:duty_byn]),
        customs_fee_byn: Pricing::Money.bd(customs[:fee_byn]),
        customs_total_byn: customs_total,
        customs_details: customs[:details],
        customs_included_in_card_price: threshold_exceeded,
        customs_threshold_exceeded: threshold_exceeded,
        card_price_byn: card_price,
        pricing_available: true,
        pricing_status: "ok",
        pricing_errors: []
      }
    rescue Pricing::ConfigurationError => e
      Rails.logger.error("[PriceCalculationService] #{e.message}")
      unavailable_unit(
        ikea_price_pln: ikea_price_pln,
        price_addon_pln: price_addon_pln,
        effective_price_p_pln: effective_p_pln(ikea_price_pln, price_addon_pln),
        weight_kg: weight_kg,
        d_ikea_pln: d_ikea_pln,
        pln_byn_raw: pln_rate,
        exchange_rate_buffer: buffer,
        errors: ["missing_configuration"]
      )
    end

    def for_product(product, pln_rate: nil, eur_rate: nil, buffer: nil, date: nil)
      date ||= Date.current
      pln_rate ||= ExchangeRate.fetch_or_create("PLN", date)&.rate_per_unit
      eur_rate ||= ExchangeRate.fetch_or_create("EUR", date)&.rate_per_unit

      unit_breakdown(
        ikea_price_pln: product&.price,
        price_addon_pln: product&.price_addon_pln,
        weight_kg: product&.packaging_weight_kg,
        d_ikea_pln: product&.delivery_cost,
        pln_rate: pln_rate,
        eur_rate: eur_rate,
        buffer: buffer
      )
    end

    def product_storefront_price_byn(product_price_zl, weight_kg: nil, delivery_pln: nil, pln_rate: nil, buffer: nil, date: nil, price_addon_pln: 0, eur_rate: nil)
      date ||= Date.current
      pln_rate ||= ExchangeRate.fetch_or_create("PLN", date)&.rate_per_unit
      eur_rate ||= ExchangeRate.fetch_or_create("EUR", date)&.rate_per_unit

      breakdown = unit_breakdown(
        ikea_price_pln: product_price_zl,
        price_addon_pln: price_addon_pln,
        weight_kg: weight_kg,
        d_ikea_pln: delivery_pln,
        pln_rate: pln_rate,
        eur_rate: eur_rate,
        buffer: buffer
      )

      return nil unless breakdown[:pricing_available]

      Pricing::Money.to_f_round2(breakdown[:card_price_byn])
    end

    def product_price_byn(product_price_zl, weight_kg: nil, delivery_pln: nil, pln_rate: nil, buffer: nil, date: nil, price_addon_pln: 0, eur_rate: nil)
      product_storefront_price_byn(
        product_price_zl,
        weight_kg: weight_kg,
        delivery_pln: delivery_pln,
        pln_rate: pln_rate,
        buffer: buffer,
        date: date,
        price_addon_pln: price_addon_pln,
        eur_rate: eur_rate
      )
    end

    def line_total_pln(unit_price_zl:, quantity:, weight_kg:, delivery_unit_pln:, price_addon_pln: 0)
      breakdown = line_breakdown_pln(
        unit_price_zl: unit_price_zl,
        quantity: quantity,
        weight_kg: weight_kg,
        delivery_unit_pln: delivery_unit_pln,
        price_addon_pln: price_addon_pln
      )
      breakdown[:total_pln]
    end

    def line_breakdown_pln(unit_price_zl:, quantity:, weight_kg:, delivery_unit_pln:, price_addon_pln: 0)
      qty = quantity.to_i
      return empty_line_breakdown if qty <= 0

      unit = unit_pln_components(
        ikea_price_pln: unit_price_zl,
        price_addon_pln: price_addon_pln,
        weight_kg: weight_kg,
        d_ikea_pln: delivery_unit_pln
      )
      return empty_line_breakdown.merge(pricing_available: false, pricing_errors: unit[:pricing_errors]) unless unit[:pricing_available]

      {
        mode: unit[:pricing_mode],
        markup_k: unit[:markup_rate].to_f,
        goods_pln: Pricing::Money.to_f_round2(unit[:goods_pln] * qty),
        delivery_pln: Pricing::Money.to_f_round2(unit[:d_ikea_pln] * qty),
        wc_by_pln: Pricing::Money.to_f_round2(unit[:wc_pln] * qty),
        base_pln: Pricing::Money.to_f_round2(unit[:subtotal_pln] * qty),
        total_pln: Pricing::Money.to_f_round2(unit[:subtotal_pln] * qty),
        pricing_available: true,
        pricing_errors: []
      }
    end

    def line_byn_components(unit_price_zl:, quantity: 1, weight_kg: nil, delivery_unit_pln: 0, pln_rate: nil, buffer: nil, date: nil, price_addon_pln: 0, eur_rate: nil)
      qty = quantity.to_i
      return empty_line_byn_components if qty <= 0

      date ||= Date.current
      pln_rate ||= ExchangeRate.fetch_or_create("PLN", date)&.rate_per_unit
      eur_rate ||= ExchangeRate.fetch_or_create("EUR", date)&.rate_per_unit
      buffer ||= exchange_rate_buffer

      unit = unit_breakdown(
        ikea_price_pln: unit_price_zl,
        price_addon_pln: price_addon_pln,
        weight_kg: weight_kg,
        d_ikea_pln: delivery_unit_pln,
        pln_rate: pln_rate,
        eur_rate: eur_rate,
        buffer: buffer
      )
      return empty_line_byn_components.merge(pricing_available: false, pricing_errors: unit[:pricing_errors]) unless unit[:pricing_available]

      rate = unit[:pln_byn_raw] * unit[:exchange_rate_buffer]
      {
        goods_byn: Pricing::Money.to_f_round2(unit[:goods_pln] * qty * rate),
        delivery_poland_byn: Pricing::Money.to_f_round2(unit[:d_ikea_pln] * qty * rate),
        delivery_belarus_byn: Pricing::Money.to_f_round2(unit[:wc_pln] * qty * rate),
        total_byn: Pricing::Money.to_f_round2(unit[:base_price_byn] * qty),
        base_price_byn: Pricing::Money.to_f_round2(unit[:base_price_byn] * qty),
        card_price_byn: Pricing::Money.to_f_round2(unit[:card_price_byn]),
        pricing_available: true,
        pricing_errors: []
      }
    end

    def empty_line_breakdown
      {
        mode: :cheap,
        markup_k: 0.0,
        goods_pln: 0.0,
        delivery_pln: 0.0,
        wc_by_pln: 0.0,
        base_pln: 0.0,
        total_pln: 0.0,
        pricing_available: false,
        pricing_errors: []
      }
    end

    def empty_line_byn_components
      {
        goods_byn: 0.0,
        delivery_poland_byn: 0.0,
        delivery_belarus_byn: 0.0,
        total_byn: 0.0,
        base_price_byn: 0.0,
        card_price_byn: nil,
        pricing_available: false,
        pricing_errors: []
      }
    end

    def calculate(product_price_zl, weight_kg, use_gls_pickup: false, delivery_pln: nil, date: nil, price_addon_pln: 0)
      date ||= Date.current
      pln_rate = ExchangeRate.fetch_or_create("PLN", date)&.rate_per_unit
      eur_rate = ExchangeRate.fetch_or_create("EUR", date)&.rate_per_unit
      return { error: "Не удалось получить курсы валют" } unless pln_rate && eur_rate

      delivery_zl = if delivery_pln.nil?
                      PolandDeliveryService.calculate(weight_kg, use_gls_pickup: use_gls_pickup)
                    else
                      delivery_pln
                    end

      unit = unit_breakdown(
        ikea_price_pln: product_price_zl,
        price_addon_pln: price_addon_pln,
        weight_kg: weight_kg,
        d_ikea_pln: delivery_zl,
        pln_rate: pln_rate,
        eur_rate: eur_rate
      )
      return { error: pricing_error_message(unit) } unless unit[:pricing_available]

      buffer = unit[:exchange_rate_buffer]
      rate = unit[:pln_byn_raw] * buffer
      {
        product_price_zl: Pricing::Money.to_f_round2(unit[:ikea_price_pln]),
        price_addon_pln: Pricing::Money.to_f_round2(unit[:price_addon_pln]),
        effective_price_p_pln: Pricing::Money.to_f_round2(unit[:effective_price_p_pln]),
        product_price_byn: Pricing::Money.to_f_round2(unit[:goods_pln] * rate),
        weight_kg: Pricing::Money.to_f_round2(unit[:weight_kg]),
        markup_k: unit[:markup_rate].to_f.round(6),
        pricing_mode: unit[:pricing_mode].to_s,
        cheap_threshold_pln: cheap_threshold_pln.round(2),
        cheap_multiplier: cheap_multiplier,
        goods_pln: Pricing::Money.to_f_round2(unit[:goods_pln]),
        delivery_pln: Pricing::Money.to_f_round2(unit[:d_ikea_pln]),
        poland_delivery_zl: Pricing::Money.to_f_round2(unit[:d_ikea_pln]),
        poland_delivery_byn: Pricing::Money.to_f_round2(unit[:d_ikea_pln] * rate),
        belarus_delivery_zl: Pricing::Money.to_f_round2(unit[:wc_pln]),
        belarus_delivery_byn: Pricing::Money.to_f_round2(unit[:wc_pln] * rate),
        wc_rate: unit[:wc_rate].to_f,
        pln_rate: unit[:pln_byn_raw].to_f.round(4),
        eur_rate: eur_rate.to_f.round(4),
        exchange_rate_buffer: buffer.to_f,
        pln_rate_with_buffer: rate.to_f.round(4),
        customs_cost_eur: unit[:customs_cost_eur]&.to_f,
        customs_duty_eur: unit.dig(:customs_details, :duty_by_cost_eur) || 0,
        customs_duty_byn: Pricing::Money.to_f_round2(unit[:customs_duty_byn]),
        customs_fee_byn: Pricing::Money.to_f_round2(unit[:customs_fee_byn]),
        customs_total_byn: Pricing::Money.to_f_round2(unit[:customs_total_byn]),
        customs_details: unit[:customs_details],
        customs_included_in_card_price: unit[:customs_included_in_card_price],
        total_pln: Pricing::Money.to_f_round2(unit[:subtotal_pln]),
        base_price_byn: Pricing::Money.to_f_round2(unit[:base_price_byn]),
        total_price_byn: Pricing::Money.to_f_round2(unit[:card_price_byn]),
        card_price_byn: Pricing::Money.to_f_round2(unit[:card_price_byn]),
        breakdown: {
          product: Pricing::Money.to_f_round2(unit[:goods_pln] * rate),
          poland_delivery: Pricing::Money.to_f_round2(unit[:d_ikea_pln] * rate),
          belarus_delivery: Pricing::Money.to_f_round2(unit[:wc_pln] * rate),
          customs: unit[:customs_included_in_card_price] ? Pricing::Money.to_f_round2(unit[:customs_total_byn]) : 0.0,
          total: Pricing::Money.to_f_round2(unit[:card_price_byn])
        }
      }
    rescue Pricing::ConfigurationError => e
      { error: e.message }
    end

    def public_payload(breakdown)
      available = breakdown[:pricing_available]
      {
        pricing_available: available,
        pricing_status: breakdown[:pricing_status],
        pricing_errors: Array(breakdown[:pricing_errors]),
        base_price_byn: available ? Pricing::Money.to_f_round2(breakdown[:base_price_byn]) : nil,
        customs_estimate_byn: available ? Pricing::Money.to_f_round2(breakdown[:customs_total_byn]) : nil,
        customs_included_in_card_price: breakdown[:customs_included_in_card_price] || false,
        customs_threshold_exceeded: breakdown[:customs_threshold_exceeded] || false,
        display_price_byn: available ? Pricing::Money.to_f_round2(breakdown[:card_price_byn]) : nil,
        price_byn: available ? format_delimited(breakdown[:card_price_byn]) : nil,
        customs_notice: CUSTOMS_NOTICE
      }
    end

    private

    def unit_pln_components(ikea_price_pln:, price_addon_pln:, weight_kg:, d_ikea_pln:)
      errors = []
      ikea = Pricing::Money.bd(ikea_price_pln)
      errors << "missing_ikea_price" if ikea.nil? || ikea <= 0
      errors << "missing_weight" if weight_kg.nil? || Pricing::Money.bd(weight_kg).nil? || Pricing::Money.bd(weight_kg) <= 0
      errors << "missing_ikea_delivery" if d_ikea_pln.nil?

      addon = [Pricing::Money.bd(price_addon_pln) || BigDecimal("0"), BigDecimal("0")].max
      p = (ikea || BigDecimal("0")) + addon
      wc = BelarusDeliveryService.quote(weight_kg)
      errors << "missing_weight" if wc.nil? && !errors.include?("missing_weight")

      if errors.any?
        return { pricing_available: false, pricing_errors: errors.uniq }
      end

      mode = pricing_mode_for(p)
      markup_rate = mode == :cheap ? (Pricing::Settings.cheap_multiplier - 1) : compute_k(p)
      goods = mode == :cheap ? (p * Pricing::Settings.cheap_multiplier) : (p * (1 + markup_rate))
      d_ikea = Pricing::Money.bd(d_ikea_pln)

      {
        pricing_available: true,
        pricing_errors: [],
        pricing_mode: mode,
        markup_rate: markup_rate,
        goods_pln: goods,
        d_ikea_pln: d_ikea,
        wc_pln: wc[:amount_pln],
        subtotal_pln: goods + d_ikea + wc[:amount_pln]
      }
    rescue Pricing::ConfigurationError => e
      Rails.logger.error("[PriceCalculationService] #{e.message}")
      { pricing_available: false, pricing_errors: ["missing_configuration"] }
    end

    def unavailable_unit(ikea_price_pln:, price_addon_pln:, effective_price_p_pln:, weight_kg:, d_ikea_pln:, pln_byn_raw:, exchange_rate_buffer:, errors:)
      {
        ikea_price_pln: Pricing::Money.bd(ikea_price_pln),
        price_addon_pln: Pricing::Money.bd(price_addon_pln) || BigDecimal("0"),
        effective_price_p_pln: Pricing::Money.bd(effective_price_p_pln),
        pricing_mode: nil,
        markup_rate: nil,
        goods_pln: nil,
        weight_kg: Pricing::Money.bd(weight_kg),
        wc_rate: nil,
        wc_pln: nil,
        d_ikea_pln: Pricing::Money.bd(d_ikea_pln),
        subtotal_pln: nil,
        pln_byn_raw: Pricing::Money.bd(pln_byn_raw),
        exchange_rate_buffer: Pricing::Money.bd(exchange_rate_buffer),
        base_price_byn: nil,
        customs_cost_eur: nil,
        customs_duty_byn: nil,
        customs_fee_byn: nil,
        customs_total_byn: nil,
        customs_details: nil,
        customs_included_in_card_price: false,
        customs_threshold_exceeded: false,
        card_price_byn: nil,
        pricing_available: false,
        pricing_status: "requires_clarification",
        pricing_errors: Array(errors).uniq
      }
    end

    def zero_customs
      {
        duty_eur: 0.0,
        duty_byn: 0.0,
        fee_byn: 0.0,
        total_byn: 0.0,
        details: {}
      }
    end

    def format_delimited(value)
      number = Pricing::Money.to_f_round2(value)
      return nil if number.nil?

      ActionController::Base.helpers.number_with_delimiter(number, delimiter: " ")
    end

    def pricing_error_message(unit)
      errors = Array(unit[:pricing_errors])
      return "Не удалось рассчитать цену" if errors.empty?

      labels = {
        "missing_weight" => "нет корректного веса упаковки",
        "missing_ikea_delivery" => "нет стоимости D_IKEA",
        "missing_ikea_price" => "нет цены IKEA",
        "missing_exchange_rate" => "нет курса валют",
        "missing_configuration" => "не заданы настройки калькулятора"
      }
      "Цена уточняется: #{errors.map { |key| labels[key] || key }.join(", ")}"
    end
  end
end
