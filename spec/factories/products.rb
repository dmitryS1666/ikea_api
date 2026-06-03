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

      detail = {
        "weight" => "#{w} кг",
        "count" => 1
      }

      if product.package_dimensions.present?
        parts = product.package_dimensions.to_s.split(/\s*[×x]\s*/i).map(&:strip)
        detail["width"] = parts[0] if parts[0].present?
        detail["height"] = parts[1] if parts[1].present?
        detail["length"] = parts[2] if parts[2].present?
      end

      dm = (fa["dimensions_map"] || {}).deep_dup
      dm["packaging"] = {
        "details" => [detail]
      }
      fa = fa.deep_dup
      fa["dimensions_map"] = dm
      product.full_attributes = fa
    end
  end
end
