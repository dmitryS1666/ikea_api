class ReindexProductFiltersJob < ApplicationJob
  queue_as :parser

  def perform(product_id, category_ids = nil)
    product = Product.find_by(id: product_id)
    return unless product

    categories = if category_ids.present?
                   Category.where(ikea_id: category_ids)
                 else
                   product.categories
                 end

    categories.find_each do |category|
      Products::FilterValuesIndexer.new(category).reindex_product(product)
    end
  end
end
