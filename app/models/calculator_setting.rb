class CalculatorSetting < ApplicationRecord
  JSON_KEYS = %w[belarus_delivery_rates poland_delivery_rates ikea_delivery_config].freeze

  PRICE_AFFECTING_KEYS = %w[
    pricing_cheap_threshold_pln
    pricing_cheap_multiplier
    pricing_target_profit_pln
    pricing_markup_subtrahend
    pricing_min_markup
    exchange_rate_buffer
    poland_vat_multiplier
    belarus_delivery_rates
    poland_delivery_rates
    ikea_delivery_config
    gls_pickup_free_weight
    customs_free_cost_limit
    customs_free_weight_limit
    customs_cost_duty_rate
    customs_weight_duty_rate
    customs_fee
  ].freeze

  validates :key, presence: true, uniqueness: true
  validates :value, presence: true
  validates :setting_type, presence: true, inclusion: { in: %w[decimal integer json] }
  validate :validate_json_value

  after_commit :clear_cache

  def decimal_value
    return nil unless setting_type == "decimal"

    value.to_f
  end

  def integer_value
    return nil unless setting_type == "integer"

    value.to_i
  end

  def json_value
    return nil unless setting_type == "json"

    JSON.parse(value)
  rescue JSON::ParserError
    nil
  end

  def set_value(val)
    case setting_type
    when "decimal", "integer"
      self.value = val.to_s
    when "json"
      self.value = val.is_a?(String) ? val : val.to_json
    end
  end

  def self.get(key)
    Rails.cache.fetch("calculator_setting/#{key}", expires_in: 1.hour) do
      setting = find_by(key: key)
      next nil unless setting

      case setting.setting_type
      when "decimal"
        setting.decimal_value
      when "integer"
        setting.integer_value
      when "json"
        setting.json_value
      end
    end
  end

  def self.set(key, value, setting_type: "decimal", description: nil)
    setting = find_or_initialize_by(key: key)
    setting.setting_type = setting_type
    setting.description = description if description
    setting.set_value(value)
    setting.save!
    Rails.cache.delete("calculator_setting/#{key}")
    setting
  end

  def self.ensure_default(key, value, setting_type: "decimal", description: nil)
    setting = find_by(key: key)
    if setting
      if description.present? && setting.description.blank?
        setting.update_columns(description: description)
      end
      return setting
    end

    set(key, value, setting_type: setting_type, description: description)
  end

  def self.ensure_defaults
    default_catalog.each do |entry|
      ensure_default(
        entry.fetch(:key),
        entry.fetch(:value),
        setting_type: entry.fetch(:setting_type),
        description: entry[:description]
      )
    end
  end

  def self.initialize_defaults
    ensure_defaults
  end

  def group_label
    case key.to_s
    when /\Apricing_/, "exchange_rate_buffer", "poland_vat_multiplier"
      "Ценообразование"
    when /\Acustoms_/
      "Таможня"
    when /delivery/, "ikea_delivery_config", "gls_pickup_free_weight"
      "Доставка"
    else
      "Прочее"
    end
  end

  def self.default_catalog
    [
      {
        key: "exchange_rate_buffer",
        value: 1.05,
        setting_type: "decimal",
        description: "Буфер к сырому курсу PLN→BYN (1.05 = +5%). Не применяется к таможне."
      },
      {
        key: "pricing_cheap_threshold_pln",
        value: 150.0,
        setting_type: "decimal",
        description: "Порог P (PLN) для cheap-режима. При P ≤ порога goods = P × cheap_multiplier."
      },
      {
        key: "pricing_cheap_multiplier",
        value: 1.30,
        setting_type: "decimal",
        description: "Множитель cheap-режима. Применяется только к P, не к D_IKEA и не к WC."
      },
      {
        key: "pricing_target_profit_pln",
        value: 87.0,
        setting_type: "decimal",
        description: "Целевая прибыль в формуле K = max(min_markup, target_profit / P − subtrahend)."
      },
      {
        key: "pricing_markup_subtrahend",
        value: 0.187,
        setting_type: "decimal",
        description: "Вычитаемое в формуле K (K = target_profit / P − это значение)."
      },
      {
        key: "pricing_min_markup",
        value: 0.10,
        setting_type: "decimal",
        description: "Минимальная наценка K (0.10 = 10%)."
      },
      {
        key: "poland_vat_multiplier",
        value: 1.23,
        setting_type: "decimal",
        description: "VAT Польши для таможенной базы C = (IKEA / VAT) × PLN_EUR. Не включает priceAddonPln."
      },
      {
        key: "poland_delivery_rates",
        value: {
          "0-1" => 0.0,
          "1-50" => 79.0,
          "50-100" => 119.0,
          "100-200" => 169.0,
          "200-400" => 329.0,
          "400-600" => 499.0,
          "600-1000" => 599.0
        },
        setting_type: "json",
        description: "Legacy-тарифы доставки по Польше (вес → PLN). Сохранены для калькулятора, пока не заменены ikea_delivery_config."
      },
      {
        key: "belarus_delivery_rates",
        value: {
          "0-20" => 16.85,
          "20-30" => 12.81,
          "30-40" => 10.69,
          "40-1000" => 8.58
        },
        setting_type: "json",
        description: "WC: PLN за кг по диапазонам веса одной единицы. Шкала не прогрессивная: для всего веса берётся ставка диапазона."
      },
      {
        key: "ikea_delivery_config",
        value: default_ikea_delivery_config,
        setting_type: "json",
        description: "Конфиг D_IKEA: регулярные тарифы IKEA.pl зона A (Białystok) с 08.09.2026. GLS 19.99/29.99 только для parcel-eligible коробок; иначе transport. IKEA Family не применяется."
      },
      {
        key: "customs_free_cost_limit",
        value: 200.0,
        setting_type: "decimal",
        description: "Беспошлинный лимит по таможенной базе C (EUR). При C = лимиту пошлины нет, при C > лимита появляется."
      },
      {
        key: "customs_free_weight_limit",
        value: 31.0,
        setting_type: "decimal",
        description: "Беспошлинный лимит по весу (кг). При W = лимиту пошлины нет, при W > лимита появляется."
      },
      {
        key: "customs_cost_duty_rate",
        value: 0.15,
        setting_type: "decimal",
        description: "Ставка пошлины по стоимости (0.15 = 15% от превышения C)."
      },
      {
        key: "customs_weight_duty_rate",
        value: 2.0,
        setting_type: "decimal",
        description: "Ставка пошлины по весу (EUR за каждый кг сверх лимита)."
      },
      {
        key: "customs_fee",
        value: 10.0,
        setting_type: "decimal",
        description: "Таможенный сбор (BYN). Добавляется один раз на всю корзину, только если duty > 0."
      },
      {
        key: "gls_pickup_free_weight",
        value: 30.0,
        setting_type: "decimal",
        description: "Legacy: бесплатный вес GLS для PolandDeliveryService (кг)."
      },
      {
        key: "default_delivery_days",
        value: 30,
        setting_type: "integer",
        description: "Срок доставки по умолчанию (дней)."
      },
      {
        key: "show_delivery_block_global",
        value: 1,
        setting_type: "integer",
        description: "Глобально: показывать блок доставки (1 — да, 0 — нет)."
      },
      {
        key: "show_reviews_block_global",
        value: 1,
        setting_type: "integer",
        description: "Глобально: показывать блок отзывов (1 — да, 0 — нет)."
      },
      {
        key: "show_tips_block_global",
        value: 1,
        setting_type: "integer",
        description: "Глобально: показывать блок советов (1 — да, 0 — нет)."
      }
    ]
  end

  def self.placeholder_ikea_delivery_config?(config)
    methods = Array(config.is_a?(Hash) ? (config["methods"] || config[:methods]) : nil)
    return true if methods.empty?

    methods.none? do |method|
      enabled = ActiveModel::Type::Boolean.new.cast(method["enabled"] || method[:enabled])
      cost = method["cost_pln"] || method[:cost_pln] || method["price_pln"] || method[:price_pln]
      enabled && !cost.nil?
    end
  end

  def self.replace_placeholder_ikea_delivery_config!
    config = default_ikea_delivery_config
    setting = find_by(key: "ikea_delivery_config")
    if setting.nil? || placeholder_ikea_delivery_config?(setting.json_value)
      set(
        "ikea_delivery_config",
        config,
        setting_type: "json",
        description: "Конфиг D_IKEA: регулярные тарифы IKEA.pl зона A (Białystok), без IKEA Family. GLS только для parcel-eligible коробок."
      )
    end
  end

  # Регулярные тарифы IKEA.pl с 08.09.2026, зона A (Białystok 15-399).
  # IKEA Family / Business Network НЕ используются (use_member_prices: false).
  # GLS 19.99/29.99 нельзя брать только по весу: IKEA проверяет товар в корзине.
  # У нас proxy: все коробки должны иметь габариты и пройти лимиты GLS Polska.
  def self.default_ikea_delivery_config
    {
      "destination" => {
        "address" => "ul. Octowa 24",
        "postal_code" => "15-399",
        "city" => "Białystok",
        "country" => "PL",
        "zone" => "A",
        "note" => "Склад IKEYA, зона A. Регулярные цены IKEA.pl с 08.09.2026, без Family/Business Network."
      },
      "use_member_prices" => false,
      "source" => "ikea.pl delivery pricelist 2026-09-08, zone A",
      "methods" => [
        {
          "code" => "gls_home_0_25",
          "name" => "Kurier GLS do 25 kg",
          "service_code" => "ikea_gls",
          "enabled" => true,
          "cost_pln" => 19.99,
          "priority" => 10,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => true,
          "min_weight_kg" => 0,
          "max_weight_kg" => 25,
          "constraints" => {
            "min_weight_kg" => 0,
            "max_weight_kg" => 25,
            "max_length_cm" => 200,
            "max_width_cm" => 80,
            "max_height_cm" => 60,
            "max_girth_cm" => 300
          }
        },
        {
          "code" => "gls_home_25_50",
          "name" => "Kurier GLS 25–50 kg",
          "service_code" => "ikea_gls",
          "enabled" => true,
          "cost_pln" => 29.99,
          "priority" => 20,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => true,
          "min_weight_kg" => 25,
          "max_weight_kg" => 50,
          "constraints" => {
            "min_weight_kg" => 25,
            "max_weight_kg" => 50,
            "max_length_cm" => 200,
            "max_width_cm" => 80,
            "max_height_cm" => 60,
            "max_girth_cm" => 300
          }
        },
        {
          "code" => "transport_no_carry_0_50",
          "name" => "Transport bez wniesienia do 50 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 99.0,
          "priority" => 30,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 0,
          "max_weight_kg" => 50,
          "constraints" => {
            "min_weight_kg" => 0,
            "max_weight_kg" => 50
          }
        },
        {
          "code" => "transport_no_carry_50_100",
          "name" => "Transport bez wniesienia 50–100 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 139.0,
          "priority" => 40,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 50,
          "max_weight_kg" => 100,
          "constraints" => {
            "min_weight_kg" => 50,
            "max_weight_kg" => 100
          }
        },
        {
          "code" => "transport_no_carry_100_200",
          "name" => "Transport bez wniesienia 100–200 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 189.0,
          "priority" => 50,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 100,
          "max_weight_kg" => 200,
          "constraints" => {
            "min_weight_kg" => 100,
            "max_weight_kg" => 200
          }
        },
        {
          "code" => "transport_with_carry_200_400",
          "name" => "Transport z wniesieniem 200–400 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 349.0,
          "priority" => 60,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 200,
          "max_weight_kg" => 400,
          "constraints" => {
            "min_weight_kg" => 200,
            "max_weight_kg" => 400
          }
        },
        {
          "code" => "transport_with_carry_400_600",
          "name" => "Transport z wniesieniem 400–600 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 519.0,
          "priority" => 70,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 400,
          "max_weight_kg" => 600,
          "constraints" => {
            "min_weight_kg" => 400,
            "max_weight_kg" => 600
          }
        },
        {
          "code" => "transport_with_carry_600_1000",
          "name" => "Transport z wniesieniem 600–1000 kg",
          "service_code" => "ikea_transport",
          "enabled" => true,
          "cost_pln" => 619.0,
          "priority" => 80,
          "pricing_profile" => "per_unit",
          "requires_product_eligibility" => false,
          "min_weight_kg" => 600,
          "max_weight_kg" => 1000,
          "constraints" => {
            "min_weight_kg" => 600,
            "max_weight_kg" => 1000
          }
        }
      ]
    }
  end

  private

  def clear_cache
    Rails.cache.delete("calculator_setting/#{key}")
    return unless PRICE_AFFECTING_KEYS.include?(key.to_s)

    Categories::ShowCache.bust_all!
    Products::RecalculateIkeaDeliveryJob.perform_later if key.to_s == "ikea_delivery_config"
  end

  def validate_json_value
    return unless setting_type == "json"

    parsed = JSON.parse(value.to_s)
    errors.add(:value, "должен быть JSON-объектом") unless parsed.is_a?(Hash)
  rescue JSON::ParserError
    errors.add(:value, "содержит некорректный JSON")
  end
end
