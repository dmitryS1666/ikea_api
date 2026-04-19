class ReindexProductFiltersJob < ApplicationJob
  queue_as :parser

  # parameters — только указанные фильтры (например %w[f-series]); nil — все фильтры категории для товара
  def perform(product_id, category_ids = nil, parameters: nil)
    product = Product.find_by(id: product_id)
    return unless product

    # Полная строка из БД: индексатор читает full_attributes и др.; избегаем частичной загрузки из кэша/ассоциаций.
    product.reload

    categories = if category_ids.present?
                   Category.where(ikea_id: category_ids)
                 else
                   product.categories
                 end

    categories.find_each do |category|
      Products::FilterValuesIndexer.new(category, parameters: parameters).reindex_product(product)
    end
  end
end
