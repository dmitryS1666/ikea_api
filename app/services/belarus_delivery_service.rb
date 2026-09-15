# Сервис для расчета весовой логистики по Беларуси (в PLN)
class BelarusDeliveryService
  class << self
    def delivery_rates
      rates = Pricing::Settings.belarus_delivery_rates

      rates.map { |range, price_per_kg| [parse_range(range), price_per_kg] }.sort_by { |range, _rate| range[0] }
    end

    def parse_range(range_str)
      parts = range_str.split("-").map(&:to_f)
      [parts[0], parts[1] || Float::INFINITY]
    end

    def quote(weight_kg)
      return nil if weight_kg.nil?

      weight = Pricing::Money.bd(weight_kg)
      return nil if weight.nil? || weight <= 0

      rate = rate_for(weight)
      return nil if rate.nil?

      amount = weight * Pricing::Money.bd(rate)
      {
        weight_kg: weight,
        rate: Pricing::Money.bd(rate),
        amount_pln: amount
      }
    end

    def calculate(weight_kg)
      quoted = quote(weight_kg)
      return 0.0 if quoted.nil?

      Pricing::Money.to_f_round2(quoted[:amount_pln])
    end

    private

    def rate_for(weight)
      rates = delivery_rates
      matched = rates.find do |(min_weight, max_weight), _rate|
        weight > min_weight && weight <= max_weight
      end

      (matched || rates.last)&.last
    end
  end
end
