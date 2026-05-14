FactoryBot.define do
  factory :product do
    sequence(:sku) { |n| "SKU#{n}" }
    name { "Test Product" }
    price { 100.0 }
    quantity { 10 }

    # Расчёты используют только вес из упаковки в `full_attributes`; для спеков с полем `weight`
    # подставляем синтетическую упаковку с тем же числом.
    after(:build) do |product|
      fa = product.full_attributes
      fa = {} unless fa.is_a?(Hash)

      if fa.dig("dimensions_map", "packaging", "details").is_a?(Array) && fa.dig("dimensions_map", "packaging", "details").any?
        product.full_attributes = fa
        next
      end

      w = product.weight
      if w.blank? || w.to_f <= 0
        product.full_attributes = fa
        next
      end

      dm = (fa["dimensions_map"] || {}).deep_dup
      dm["packaging"] = {
        "details" => [
          {
            "weight" => "#{w} кг",
            "count" => 1,
            "width" => "20 см",
            "height" => "30 см",
            "length" => "40 см"
          }
        ]
      }
      fa = fa.deep_dup
      fa["dimensions_map"] = dm
      product.full_attributes = fa
    end
  end
end
