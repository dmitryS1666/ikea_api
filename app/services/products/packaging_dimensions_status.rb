# frozen_string_literal: true

module Products
  # Единые правила с консольными проверками и джобой восполнения:
  # «полноценные размеры упаковки» = ширина + высота + (глубина или длина)
  # в customer payload size — либо в packaging.details (ключи width/height/length|depth),
  # либо в size.packages[].measurements (русские имена после translate_measurement_label_for_api).
  class PackagingDimensionsStatus
    class << self
      def package_measurements_have_box_dims?(pkg)
        return false unless pkg.is_a?(Hash)

        names = Array(pkg["measurements"]).filter_map do |row|
          next unless row.is_a?(Hash)

          ProductSerializer.translate_measurement_label_for_api(row["name"] || row[:name])
        end.compact.map(&:to_s)

        names.include?("Ширина") &&
          names.include?("Высота") &&
          (names.include?("Глубина") || names.include?("Длина"))
      end

      def packaging_details_have_box_dims?(pack)
        return false unless pack.is_a?(Hash)

        Array(pack["details"]).any? do |row|
          next false unless row.is_a?(Hash)

          r = row.stringify_keys
          r["width"].present? &&
            r["height"].present? &&
            (r["length"].present? || r["depth"].present?)
        end
      end

      def size_has_full_packaging_dimensions?(size)
        return false unless size.is_a?(Hash)

        pack = size["packaging"]
        return true if packaging_details_have_box_dims?(pack)

        Array(size["packages"]).any? { |pkg| package_measurements_have_box_dims?(pkg) }
      end

      def full_packaging_dimensions_in_customer_payload?(product)
        size = ProductSerializer.customer_full_attributes_payload(product)["size"]
        size_has_full_packaging_dimensions?(size)
      end

      def missing_full_packaging_dimensions?(product)
        !full_packaging_dimensions_in_customer_payload?(product)
      end

      # Сырой measurements_modal из парсера (до customer payload): есть ли хотя бы одна упаковка
      # с тройкой Ширина + Высота + (Глубина|Длина) в measurements.
      def modal_has_full_packaging_dimensions?(measurements_modal)
        return false unless measurements_modal.is_a?(Hash)

        mm = measurements_modal.deep_stringify_keys
        packages = ProductSerializer.extract_packages_from_measurements_modal(mm)
        packages.any? { |pkg| package_measurements_have_box_dims?(pkg) }
      end
    end
  end
end
