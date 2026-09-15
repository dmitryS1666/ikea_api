# frozen_string_literal: true

class SeedPricingCalculatorSettings < ActiveRecord::Migration[7.1]
  class LegacyCalculatorSetting < ActiveRecord::Base
    self.table_name = "calculator_settings"
  end

  def up
    return unless table_exists?(:calculator_settings)

    CalculatorSetting.ensure_defaults

    copy_legacy_markup_subtrahend_if_needed
  end

  def down
    %w[
      pricing_cheap_threshold_pln
      pricing_cheap_multiplier
      pricing_target_profit_pln
      pricing_markup_subtrahend
      pricing_min_markup
      poland_vat_multiplier
      ikea_delivery_config
    ].each do |key|
      CalculatorSetting.where(key: key).delete_all
    end
  end

  private

  def copy_legacy_markup_subtrahend_if_needed
    pricing = LegacyCalculatorSetting.find_by(key: "pricing_markup_subtrahend")
    legacy = LegacyCalculatorSetting.find_by(key: "markup_subtrahend")
    return unless pricing && legacy
    return unless pricing.created_at && legacy.created_at
    return unless (pricing.updated_at - pricing.created_at).abs < 2

    pricing.update!(value: legacy.value.to_s)
    Rails.cache.delete("calculator_setting/pricing_markup_subtrahend")
  rescue StandardError => e
    say "skip legacy markup_subtrahend copy: #{e.class}: #{e.message}"
  end
end
