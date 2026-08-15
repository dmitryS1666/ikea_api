# frozen_string_literal: true

module Products
  # SKU из листинга IKEA `gprDescription.variants` — уже готовые комплектации,
  # не декартово произведение осей (цвет × размер × дно).
  #
  # Берём только строки с PIP `/p/`, один уровень, с жёстким потолком:
  # иначе актуализация категории уходит в разворот вариантов вариантов.
  class ListingVariantSkus
    MAX_PER_PARENT = 8
    SKU_PATTERN = /\A[sS]?\d{8}\z/

    def self.from_listing_row(product_data, parent_sku: nil, exclude: [])
      extract(variants_array(product_data), parent_sku: parent_sku, exclude: exclude)
    end

    def self.extract(variants, parent_sku: nil, exclude: [])
      parent_aliases = alias_set(parent_sku)
      exclude_aliases = Array(exclude).each_with_object(parent_aliases.dup) do |sku, memo|
        alias_set(sku).each { |key| memo << key }
      end

      seen = exclude_aliases.dup
      skus = []

      Array(variants).each do |row|
        sku = sku_from_variant_row(row)
        next if sku.blank? || !sku.match?(SKU_PATTERN)

        aliases = alias_set(sku)
        next if aliases.any? { |key| seen.include?(key) }

        aliases.each { |key| seen << key }
        skus << sku
        break if skus.size >= MAX_PER_PARENT
      end

      skus
    end

    def self.variants_array(product_data)
      return [] unless product_data.is_a?(Hash)

      row = product_data.stringify_keys
      gpr = row["gprDescription"]
      gpr = gpr.stringify_keys if gpr.is_a?(Hash)
      Array(gpr.is_a?(Hash) ? gpr["variants"] : nil)
    end

    def self.sku_from_variant_row(row)
      return ListingSkuResolver.coerce_listing_identifier(row) unless row.is_a?(Hash)

      hash = row.respond_to?(:deep_stringify_keys) ? row.deep_stringify_keys : row.transform_keys(&:to_s)
      pip = hash["pipUrl"].presence || hash["url"].presence || ""
      return nil unless pip.to_s.include?("/p/")

      ListingSkuResolver.coerce_listing_identifier(hash)
    end

    def self.alias_set(raw)
      ListingSkuResolver.aliases(raw).map(&:to_s).to_set
    end
    private_class_method :alias_set
  end
end
