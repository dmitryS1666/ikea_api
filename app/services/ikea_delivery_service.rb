# frozen_string_literal: true

class IkeaDeliveryService
  class << self
    def quote(product)
      return nil unless product.is_a?(Product)

      config = Pricing::Settings.ikea_delivery_config
      methods = Array(config["methods"] || config[:methods])
      packages = Delivery::ParcelPackingService.parcel_metrics_list(product)
      weight_kg = Products::WeightExtractor.packaging_weight_kg_for_product(product)

      candidates = methods.filter_map do |method|
        next unless method_enabled?(method)
        next unless cost_present?(method)
        next unless matches?(method, packages: packages, weight_kg: weight_kg)

        cost = cost_for(method, packages: packages)
        next if cost.nil?

        {
          delivery_type: method["service_code"].presence || method["code"].to_s,
          delivery_name: method["name"].presence || method["code"].to_s,
          delivery_reason: reason_for(method, weight_kg: weight_kg),
          cost_pln: cost,
          priority: method["priority"].to_i
        }
      end

      candidates.min_by { |row| [Pricing::Money.bd(row[:cost_pln]), row[:priority]] }
    rescue Pricing::ConfigurationError => e
      Rails.logger.error("[IkeaDeliveryService] #{e.message}")
      nil
    end

    def destination
      config = Pricing::Settings.ikea_delivery_config
      config["destination"] || config[:destination]
    rescue Pricing::ConfigurationError
      nil
    end

    private

    def method_enabled?(method)
      ActiveModel::Type::Boolean.new.cast(method["enabled"] || method[:enabled])
    end

    def cost_present?(method)
      cost = method_cost(method)
      return false if cost.nil?

      number = Pricing::Money.bd(cost)
      number && number >= 0
    end

    def method_cost(method)
      method["cost_pln"] || method[:cost_pln] || method["price_pln"] || method[:price_pln]
    end

    def cost_for(method, packages:)
      unit_cost = Pricing::Money.bd(method_cost(method))
      return nil if unit_cost.nil?

      profile = (method["pricing_profile"] || method[:pricing_profile]).to_s
      if profile == "per_package"
        count = [packages.size, 1].max
        return unit_cost * count
      end

      unit_cost
    end

    def matches?(method, packages:, weight_kg:)
      constraints = method["constraints"] || method[:constraints] || {}
      packages = Array(packages)

      return false unless weight_in_band?(weight_kg, method, constraints)

      if eligibility_required?(method)
        return false if packages.empty?
        return false unless packages.all? { |package| complete_package?(package) }
      end

      max_packages = numeric(lookup(method, constraints, "max_packages"))
      return false if max_packages && packages.size > max_packages

      max_package_weight = numeric(lookup(method, constraints, "max_weight_kg_per_package"))
      max_length = numeric(lookup(method, constraints, "max_length_cm"))
      max_width = numeric(lookup(method, constraints, "max_width_cm"))
      max_height = numeric(lookup(method, constraints, "max_height_cm"))
      max_girth = numeric(lookup(method, constraints, "max_girth_cm"))

      dimension_limits = [max_length, max_width, max_height, max_girth].any?
      return true if packages.empty? && !dimension_limits && !eligibility_required?(method)

      packages.all? do |package|
        package_ok?(
          package,
          max_package_weight: max_package_weight,
          max_length: max_length,
          max_width: max_width,
          max_height: max_height,
          max_girth: max_girth
        )
      end
    end

    def weight_in_band?(weight_kg, method, constraints)
      return false if weight_kg.nil?

      weight = weight_kg.to_f
      min = numeric(lookup(method, constraints, "min_weight_kg"))
      max = numeric(lookup(method, constraints, "max_weight_kg"))

      return false if min && min.positive? && weight <= min
      return false if max && weight > max

      true
    end

    def eligibility_required?(method)
      ActiveModel::Type::Boolean.new.cast(
        method["requires_product_eligibility"] || method[:requires_product_eligibility]
      )
    end

    def complete_package?(package)
      weight = package[:weight_kg]
      return false if weight.nil? || weight.to_f <= 0

      sides = [package[:width_cm], package[:height_cm], package[:depth_cm]].map(&:to_f)
      sides.size == 3 && sides.all?(&:positive?)
    end

    def package_ok?(package, max_package_weight:, max_length:, max_width:, max_height:, max_girth:)
      weight = package[:weight_kg]
      return false if max_package_weight && (weight.nil? || weight.to_f > max_package_weight)

      sides = [package[:width_cm], package[:height_cm], package[:depth_cm]].map { |side| side&.to_f }.compact.sort.reverse
      return false if (max_length || max_width || max_height || max_girth) && sides.size < 3

      length, width, height = sides
      return false if max_length && length > max_length
      return false if max_width && width > max_width
      return false if max_height && height > max_height
      return false if max_girth && (length + (2 * width) + (2 * height) > max_girth)

      true
    end

    def lookup(method, constraints, key)
      method[key] || method[key.to_sym] || constraints[key] || constraints[key.to_sym]
    end

    def reason_for(method, weight_kg:)
      code = method["code"] || method[:code]
      if eligibility_required?(method)
        "auto: parcel-eligible, W=#{weight_kg} matches configured #{code} limits"
      else
        "auto: W=#{weight_kg} matches configured #{code} limits"
      end
    end

    def numeric(value)
      return nil if value.nil? || value == ""

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
