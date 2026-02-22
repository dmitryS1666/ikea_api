class ReindexCategoryFiltersJob < ApplicationJob
  queue_as :parser

  def perform(category_id)
    category = Category.find_by(ikea_id: category_id)
    return unless category

    Products::FilterValuesIndexer.new(category).reindex!
  end
end
