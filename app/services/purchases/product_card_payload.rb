module Purchases
  class ProductCardPayload
    CARD_KEYS = %i[
      sku
      slug
      name
      name_ru
      translated_name
      small_desc_name
      price_byn
      local_images
      variants
    ].freeze

    def self.call(product, params: nil)
      return nil unless product

      attributes =
        ProductTeaserSerializer
          .new(product, { params: params || default_params })
          .serializable_hash
          .dig(:data, :attributes)
          .to_h
          .symbolize_keys

      payload = attributes.slice(*CARD_KEYS)
      payload[:translated_name] = payload[:name_ru] if payload[:name_ru].present?
      payload[:variants] = Array(payload[:variants])
      payload
    end

    def self.default_params
      {
        rates: {
          pln: ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
        },
        calculator_settings: {
          "exchange_rate_buffer" => CalculatorSetting.get("exchange_rate_buffer")
        }
      }
    end
  end
end
