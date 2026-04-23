# frozen_string_literal: true

module Products
  class WeightRecoveryService
    VGH_COLUMN_KEYS = %i[weight net_weight package_volume package_dimensions dimensions].freeze

    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
    end

    def call
      Rails.logger.info "[WeightRecovery] Starting for SKU: #{@product.sku}, URL: #{@product.url}"
      return { status: :error, message: "Product URL is missing" } if @product.url.blank?

      # PlDetailsFetcher по URL товара (часто PL). Для категорий с LT приоритет веса/габаритов —
      # см. Products::ExtendedAttributesFetchService (LT PIP / JSONL, затем добор с PL).
      begin
        Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Fetching simple HTML..."
        pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: false, scope_sku: @product.sku) || {}
        
        if pl_details[:weight].blank? && pl_headless_enabled?
          Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Weight not found in simple HTML, trying headless..."
          # Если не нашли вес простым запросом, пробуем через headless (медленнее, но надежнее для модалок)
          pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: true, scope_sku: @product.sku) || {}
        end

        updates = vgh_updates(pl_details)
        full_attributes_updates = full_attributes_vgh_updates(pl_details)

        if updates.any? || full_attributes_updates.any?
          apply_updates!(updates, full_attributes_updates)
          weight = @product.reload.weight
          Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Success! Updated VGH fields: #{(updates.keys + full_attributes_updates.keys).join(', ')}"
          { status: :success, weight: weight }
        elsif pl_details[:weight].present?
          weight = @product.weight.presence || pl_details[:weight].to_f
          Rails.logger.info "[WeightRecovery] [#{ @product.sku }] VGH found but nothing to update"
          { status: :success, weight: weight, unchanged: true }
        else
          Rails.logger.warn "[WeightRecovery] [#{ @product.sku }] Weight NOT found on page"
          { status: :not_found, message: "Weight not found on page" }
        end
      rescue StandardError => e
        Rails.logger.error "[WeightRecovery] [#{ @product.sku }] FATAL ERROR: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        { status: :error, message: "#{e.class}: #{e.message}" }
      end
    end

    private

    def vgh_updates(pl_details)
      updates = {}

      VGH_COLUMN_KEYS.each do |key|
        next unless pl_details[key].present?
        next unless @product.read_attribute(key).blank?

        updates[key] = key == :weight ? pl_details[key].to_f : pl_details[key]
      end

      updates
    end

    def full_attributes_vgh_updates(pl_details)
      updates = {}
      measurements_modal = pl_details[:measurements_modal]
      return updates unless measurements_modal.present?

      full = @product.full_attributes.is_a?(Hash) ? @product.full_attributes.deep_dup : {}
      if full["measurements_modal"].blank?
        full["measurements_modal"] = measurements_modal.is_a?(Hash) ? measurements_modal.deep_stringify_keys : measurements_modal
        full["measurements_modal_extracted_at"] = Time.current.iso8601
      end
      if full["dimensions_map"].blank? && measurements_modal.is_a?(Hash)
        dimensions_map = {}
        Array(measurements_modal["product_measurements"] || measurements_modal[:product_measurements]).each do |row|
          next unless row.is_a?(Hash)

          name = row["name"] || row[:name]
          measure = row["measure"] || row[:measure]
          next if name.to_s.strip.blank? || measure.to_s.strip.blank?

          dimensions_map[name.to_s.strip] = measure.to_s.strip
        end
        full["dimensions_map"] = dimensions_map if dimensions_map.any?
      end

      updates[:full_attributes] = full if full.present?
      updates
    end

    def apply_updates!(updates, full_attributes_updates)
      merged = updates.merge(full_attributes_updates)
      return if merged.empty?

      @product.update!(merged)
    end

    def pl_headless_enabled?
      %w[true 1 yes].include?(ENV.fetch('PL_FETCHER_ENABLE_HEADLESS', 'true').to_s.downcase)
    end
  end
end
