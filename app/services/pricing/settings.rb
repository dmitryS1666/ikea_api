# frozen_string_literal: true

module Pricing
  class Settings
    REQUIRED_DECIMALS = %w[
      pricing_cheap_threshold_pln
      pricing_cheap_multiplier
      pricing_target_profit_pln
      pricing_markup_subtrahend
      pricing_min_markup
      exchange_rate_buffer
      poland_vat_multiplier
      customs_free_cost_limit
      customs_free_weight_limit
      customs_cost_duty_rate
      customs_weight_duty_rate
      customs_fee
    ].freeze

    class << self
      def cheap_threshold_pln
        fetch_decimal!("pricing_cheap_threshold_pln")
      end

      def cheap_multiplier
        fetch_decimal!("pricing_cheap_multiplier")
      end

      def target_profit_pln
        fetch_decimal!("pricing_target_profit_pln")
      end

      def markup_subtrahend
        fetch_decimal!("pricing_markup_subtrahend")
      end

      def min_markup
        fetch_decimal!("pricing_min_markup")
      end

      def exchange_rate_buffer
        fetch_decimal!("exchange_rate_buffer")
      end

      def vat_multiplier
        fetch_decimal!("poland_vat_multiplier")
      end

      def customs_free_cost_limit
        fetch_decimal!("customs_free_cost_limit")
      end

      def customs_free_weight_limit
        fetch_decimal!("customs_free_weight_limit")
      end

      def customs_cost_duty_rate
        fetch_decimal!("customs_cost_duty_rate")
      end

      def customs_weight_duty_rate
        fetch_decimal!("customs_weight_duty_rate")
      end

      def customs_fee
        fetch_decimal!("customs_fee")
      end

      def belarus_delivery_rates
        fetch_json!("belarus_delivery_rates")
      end

      def ikea_delivery_config
        fetch_json!("ikea_delivery_config")
      end

      def snapshot
        {
          cheap_threshold_pln: cheap_threshold_pln,
          cheap_multiplier: cheap_multiplier,
          target_profit_pln: target_profit_pln,
          markup_subtrahend: markup_subtrahend,
          min_markup: min_markup,
          exchange_rate_buffer: exchange_rate_buffer,
          vat_multiplier: vat_multiplier
        }
      end

      private

      def fetch_decimal!(key)
        value = CalculatorSetting.get(key)
        number = Pricing::Money.bd(value)
        if number.nil?
          raise_missing!(key)
        end

        number
      end

      def fetch_json!(key)
        value = CalculatorSetting.get(key)
        raise_missing!(key) unless value.is_a?(Hash)

        value
      end

      def raise_missing!(key)
        message = "Отсутствует или некорректна обязательная настройка ценообразования: #{key}"
        Rails.logger.error("[Pricing::Settings] #{message}")
        raise ConfigurationError.new(message, key: key)
      end
    end
  end
end
