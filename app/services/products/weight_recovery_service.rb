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
      return { status: :error, message: "Product URL is missing" } if @product.url.blank?

      # Используем PlDetailsFetcher для получения данных с сайта IKEA PL
      # Он уже умеет работать через прокси, если PROXY_LIST в ENV задан
      begin
        pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: false) || {}
        
        if pl_details[:weight].blank? && pl_headless_enabled?
          # Если не нашли вес простым запросом, пробуем через headless (медленнее, но надежнее для модалок)
          pl_details = PlDetailsFetcher.fetch(@product.url, use_headless: true) || {}
        end

        if pl_details[:weight].present?
          weight = pl_details[:weight].to_f
          
          # Сохраняем вес и обновляем full_attributes_ru если нужно
          @product.update!(weight: weight)
          
          # Если в деталях есть еще полезная инфа, которую мы вытащили - тоже обновим
          updates = {}
          updates[:net_weight] = pl_details[:net_weight] if pl_details[:net_weight] && @product.net_weight.blank?
          updates[:package_volume] = pl_details[:package_volume] if pl_details[:package_volume] && @product.package_volume.blank?
          updates[:package_dimensions] = pl_details[:package_dimensions] if pl_details[:package_dimensions] && @product.package_dimensions.blank?
          
          @product.update!(updates) if updates.any?

          { status: :success, weight: weight }
        else
          { status: :not_found, message: "Weight not found on page" }
        end
      rescue StandardError => e
        { status: :error, message: "#{e.class}: #{e.message}" }
      end
    end

    private

    def pl_headless_enabled?
      %w[true 1 yes].include?(ENV.fetch('PL_FETCHER_ENABLE_HEADLESS', 'true').to_s.downcase)
    end
  end
end
