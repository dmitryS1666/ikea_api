# frozen_string_literal: true

module Pricing
  module Money
    module_function

    def bd(value)
      return value if value.is_a?(BigDecimal)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def round2(value)
      number = bd(value)
      return nil if number.nil?

      number.round(2, BigDecimal::ROUND_HALF_UP)
    end

    def to_f_round2(value)
      rounded = round2(value)
      rounded&.to_f
    end
  end
end
