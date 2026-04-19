# frozen_string_literal: true

module Products
  # Сбор списка related_products с витрин PL/LT (PlDetailsFetcher) и запись в карточку
  # через ExtendedAttributesFetchService — временно отключён.
  # Включить: поставить ENABLED = true.
  module RelatedProductsCollection
    ENABLED = false
  end
end
