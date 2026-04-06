# frozen_string_literal: true

module Products
  class WeightRecoveryService
    def self.call(product)
      new(product).call
    end

    def initialize(product)
      @product = product
    end

    def call
      Rails.logger.info "[WeightRecovery] Starting for SKU: #{@product.sku}, URL: #{@product.url}"
      return { status: :error, message: "Product URL is missing" } if @product.url.blank?

      # Используем PlDetailsFetcher для получения данных с сайта IKEA PL
      # Он уже умеет работать через прокси, если PROXY_LIST в ENV задан
      begin
        Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Fetching simple HTML..."
        pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: false) || {}
        
        if pl_details[:weight].blank? && pl_headless_enabled?
          Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Weight not found in simple HTML, trying headless..."
          # Если не нашли вес простым запросом, пробуем через headless (медленнее, но надежнее для модалок)
          pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: true) || {}
        end

        if pl_details[:weight].present?
          weight = pl_details[:weight].to_f
          Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Success! Weight found: #{weight}"
          
          # Сохраняем вес и обновляем full_attributes_ru если нужно
          @product.update!(weight: weight)
          
          # Если в деталях есть еще полезная инфа, которую мы вытащили - тоже обновим
          updates = {}
          updates[:net_weight] = pl_details[:net_weight] if pl_details[:net_weight] && @product.net_weight.blank?
          updates[:package_volume] = pl_details[:package_volume] if pl_details[:package_volume] && @product.package_volume.blank?
          updates[:package_dimensions] = pl_details[:package_dimensions] if pl_details[:package_dimensions] && @product.package_dimensions.blank?
          
          if updates.any?
            Rails.logger.info "[WeightRecovery] [#{ @product.sku }] Updating additional attributes: #{updates.keys.join(', ')}"
            @product.update!(updates)
          end

          { status: :success, weight: weight }
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

    def pl_headless_enabled?
      %w[true 1 yes].include?(ENV.fetch('PL_FETCHER_ENABLE_HEADLESS', 'true').to_s.downcase)
    end
  end
end
