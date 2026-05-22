class Delivery
  class ParcelPackingService
    # TODO: tune with real provider limits from business.
    DEFAULT_MAX_WEIGHT_KG = 30.0
    DEFAULT_MAX_VOLUME_M3 = 0.25
    DEFAULT_MAX_DIMENSION_CM = 120.0

    def self.call(cart)
      parcels = build_parcels(cart)
      totals = parcel_totals(parcels)

      first_ineligible = parcels.find { |parcel| !parcel[:eligible_for_europost] }

      {
        total_weight_kg: totals[:total_weight_kg],
        total_volume_m3: totals[:total_volume_m3],
        max_dimension_cm: totals[:max_dimension_cm],
        parcels: parcels,
        eligible_for_europost: first_ineligible.nil?,
        ineligible_reason: first_ineligible&.dig(:ineligible_reason)
      }
    end

    def self.europost_limits
      {
        max_weight_kg: CalculatorSetting.get("europost_max_weight_kg") || DEFAULT_MAX_WEIGHT_KG,
        max_volume_m3: CalculatorSetting.get("europost_max_volume_m3") || DEFAULT_MAX_VOLUME_M3,
        max_dimension_cm: CalculatorSetting.get("europost_max_dimension_cm") || DEFAULT_MAX_DIMENSION_CM,
        side_dimensions_cm: normalize_side_limits(CalculatorSetting.get("europost_max_side_dimensions_cm"))
      }
    end

    def self.evaluate_parcel(parcel)
      limits = europost_limits

      return ineligible(parcel, "missing_product") if parcel[:sku].blank?
      return ineligible(parcel, "missing_weight") if parcel[:weight_kg].to_f <= 0
      return ineligible(parcel, "missing_dimensions") if [parcel[:width_cm], parcel[:height_cm], parcel[:depth_cm]].any? { |x| x.to_f <= 0 }
      return ineligible(parcel, "missing_volume") if parcel[:volume_m3].to_f <= 0

      return ineligible(parcel, "max_weight_exceeded") if parcel[:weight_kg].to_f > limits[:max_weight_kg].to_f
      return ineligible(parcel, "max_volume_exceeded") if parcel[:volume_m3].to_f > limits[:max_volume_m3].to_f

      max_dim = [parcel[:width_cm], parcel[:height_cm], parcel[:depth_cm]].map(&:to_f).max
      return ineligible(parcel, "max_dimension_exceeded") if max_dim > limits[:max_dimension_cm].to_f

      if limits[:side_dimensions_cm].present?
        parcel_sides = [parcel[:width_cm], parcel[:height_cm], parcel[:depth_cm]].map(&:to_f).sort
        side_limits = limits[:side_dimensions_cm].sort
        exceeds = parcel_sides.each_with_index.any? { |side, idx| side > side_limits[idx].to_f }
        return ineligible(parcel, "side_limits_exceeded") if exceeds
      end

      eligible(parcel)
    end

    def self.build_parcels(cart)
      items = cart_items(cart)

      items.flat_map do |item|
        quantity = item.quantity.to_i
        next [] if quantity <= 0

        product = item.product
        sku = product&.sku || item.try(:product_sku)
        product_id = product&.id
        metrics = parcel_metrics(product)

        quantity.times.map do
          parcel = {
            product_id: product_id,
            sku: sku,
            quantity: 1,
            weight_kg: metrics[:weight_kg],
            width_cm: metrics[:width_cm],
            height_cm: metrics[:height_cm],
            depth_cm: metrics[:depth_cm],
            volume_m3: metrics[:volume_m3]
          }

          evaluate_parcel(parcel)
        end
      end
    end

    def self.cart_items(cart)
      source = cart.cart_items
      # For virtual carts (e.g. CartPricingService.order_as_cart), cart_items are
      # in-memory and not persisted; calling includes() would re-query DB and drop them.
      if source.respond_to?(:all?) && source.all?(&:persisted?) && source.respond_to?(:includes)
        return source.includes(:product)
      end

      Array(source)
    end

    def self.parcel_metrics(product)
      return { weight_kg: nil, width_cm: nil, height_cm: nil, depth_cm: nil, volume_m3: nil } unless product

      weight = safe_product_weight_kg(product)
      sides = extract_sides(product)
      width, height, depth = sides

      # Business meaning:
      # - `products.package_volume` is stored in liters (see PlDetailsFetcher + admin UI label "л")
      # - VGH constraints are expressed in m³ (`*_max_volume_m3`)
      volume_m3 = (product.package_volume.to_f / 1000.0) if product.package_volume.present?
      volume_m3 = nil if volume_m3.to_f <= 0
      volume_m3 = (width.to_f * height.to_f * depth.to_f / 1_000_000.0).round(6) if volume_m3.blank? && [width, height, depth].all?(&:present?)

      {
        weight_kg: weight&.to_f,
        width_cm: width&.to_f,
        height_cm: height&.to_f,
        depth_cm: depth&.to_f,
        volume_m3: volume_m3
      }
    end

    # Лёгкий расчёт ВГХ для admin XLSX (колонки + JSON без ProductSerializer).
    def self.export_parcel_metrics(product, weight_kg: nil, customer_payload: nil)
      return { weight_kg: nil, width_cm: nil, height_cm: nil, depth_cm: nil, volume_m3: nil } unless product

      payload = customer_payload || customer_full_attributes_payload(product)
      weight = weight_kg || Products::WeightExtractor.extract_packaging_kg_from_customer_payload(payload)
      sides = extract_package_sides_from_customer_size(payload["size"]) || export_extract_sides(product)
      width, height, depth = sides || [nil, nil, nil]

      volume_m3 = (product.package_volume.to_f / 1000.0) if product.package_volume.present?
      volume_m3 = nil if volume_m3.to_f <= 0
      volume_m3 = (width.to_f * height.to_f * depth.to_f / 1_000_000.0).round(6) if volume_m3.blank? && [width, height, depth].all?(&:present?)

      {
        weight_kg: weight&.to_f,
        width_cm: width&.to_f,
        height_cm: height&.to_f,
        depth_cm: depth&.to_f,
        volume_m3: volume_m3
      }
    end

    def self.export_extract_sides(product)
      [product.package_dimensions, product.dimensions].each do |text|
        normalized = normalize_sides(extract_numbers(text))
        return normalized if normalized.present?
      end

      nil
    end
    private_class_method :export_extract_sides

    def self.extract_sides(product)
      [
        extract_numbers(product.package_dimensions),
        extract_sides_from_customer_payload(product),
        extract_numbers(product.dimensions)
      ].each do |candidates|
        numbers = normalize_sides(candidates)
        return numbers if numbers.present?
      end

      [nil, nil, nil]
    end

    def self.safe_product_weight_kg(product)
      Products::WeightExtractor.packaging_weight_kg_for_product(product)
    end

    def self.extract_sides_from_customer_payload(product)
      size = customer_full_attributes_payload(product)["size"]
      extract_package_sides_from_customer_size(size) || []
    end

    def self.extract_package_sides_from_customer_size(size)
      return nil unless size.is_a?(Hash)

      extract_sides_from_packaging_details(size) ||
        extract_sides_from_packages(size) ||
        extract_sides_from_size_block(size)
    end

    def self.customer_full_attributes_payload(product)
      return {} unless defined?(ProductSerializer)

      ProductSerializer.customer_full_attributes_payload(product)
    rescue StandardError
      {}
    end

    def self.extract_sides_from_packaging_details(size)
      Array(size.dig("packaging", "details")).each do |detail|
        next unless detail.is_a?(Hash)

        sides = [
          detail["width"],
          detail["height"],
          detail["length"] || detail["depth"]
        ].flat_map { |value| extract_numbers(value) }

        normalized = normalize_sides(sides)
        return normalized if normalized.present?
      end

      nil
    end

    def self.extract_sides_from_packages(size)
      Array(size["packages"]).each do |package|
        measurements = Array(package["measurements"])
        by_name = measurements.each_with_object({}) do |row, memo|
          next unless row.is_a?(Hash)

          memo[row["name"].to_s.downcase] = row["measure"]
        end

        sides = [
          by_name["ширина"],
          by_name["высота"],
          by_name["длина"] || by_name["глубина"]
        ].flat_map { |value| extract_numbers(value) }

        normalized = normalize_sides(sides)
        return normalized if normalized.present?
      end

      nil
    end

    def self.extract_sides_from_size_block(size)
      sides = [
        size["Ширина"] || size["width"],
        size["Высота"] || size["height"],
        size["Длина"] || size["Глубина"] || size["length"] || size["depth"]
      ].flat_map { |value| extract_numbers(value) }

      normalize_sides(sides)
    end

    def self.normalize_sides(values)
      numbers = Array(values).compact.select { |v| v.to_f.positive? }.map(&:to_f)
      return nil if numbers.size < 3

      numbers.sort.reverse.first(3)
    end

    def self.extract_numbers_from_nested(value)
      case value
      when Hash
        value.values.flat_map { |nested| extract_numbers_from_nested(nested) }
      when Array
        value.flat_map { |nested| extract_numbers_from_nested(nested) }
      when String
        extract_numbers(value)
      else
        []
      end
    end

    def self.extract_numbers(text)
      str = text.to_s
      return [] if str.blank?

      str.scan(/(\d+(?:[.,]\d+)?)\s*(cm|см|mm|мм|m|м)?/i).map do |number, unit|
        value = number.to_s.tr(",", ".").to_f
        next if value <= 0
        convert_to_cm(value, unit)
      end.compact
    end

    def self.convert_to_cm(value, unit)
      case unit.to_s.downcase
      when "mm", "мм" then value / 10.0
      when "m", "м" then value * 100.0
      else value
      end
    end

    def self.parcel_totals(parcels)
      {
        total_weight_kg: parcels.sum { |p| p[:weight_kg].to_f }.round(3),
        total_volume_m3: parcels.sum { |p| p[:volume_m3].to_f }.round(6),
        max_dimension_cm: parcels.flat_map { |p| [p[:width_cm], p[:height_cm], p[:depth_cm]].compact }.map(&:to_f).max.to_f.round(2)
      }
    end

    def self.eligible(parcel)
      parcel.merge(eligible_for_europost: true, ineligible_reason: nil)
    end

    def self.ineligible(parcel, reason)
      parcel.merge(eligible_for_europost: false, ineligible_reason: reason)
    end

    def self.normalize_side_limits(raw)
      case raw
      when Array
        values = raw.map(&:to_f).select(&:positive?)
        values.size == 3 ? values : nil
      when String
        values = raw.split(/[xх,; ]+/i).map(&:to_f).select(&:positive?)
        values.size == 3 ? values : nil
      else
        nil
      end
    end
  end
end
