class ReindexCategoryFiltersJob < ApplicationJob
  queue_as :parser

  # category_id — ikea_id категории; task_id — опционально, для отображения в ParserTask (админка «Управление парсером»)
  # parameters — только указанные parameter из available_filters (например %w[f-series]); nil — все фильтры
  # product_id — при заданном id переиндексируется только этот товар в категории (parameters опциональны)
  def perform(category_id, task_id: nil, parameters: nil, product_id: nil)
    task = ParserTask.find_by(id: task_id) if task_id.present?
    category = Category.find_by(ikea_id: category_id.to_s)
    unless category
      msg = "Категория не найдена: #{category_id}"
      Rails.logger.error "ReindexCategoryFiltersJob: #{msg}"
      task&.mark_as_failed!(msg)
      return
    end

    task&.mark_as_running!

    if product_id.present?
      product = Product.find_by(id: product_id.to_i)
      unless product
        msg = "Товар не найден: #{product_id}"
        Rails.logger.error "ReindexCategoryFiltersJob: #{msg}"
        task&.mark_as_failed!(msg)
        return
      end

      unless category.products_through_categories.where(id: product.id).exists?
        msg = "Товар #{product_id} не привязан к категории #{category_id}"
        Rails.logger.error "ReindexCategoryFiltersJob: #{msg}"
        task&.mark_as_failed!(msg)
        return
      end

      Products::FilterValuesIndexer.new(category, parameters: parameters).reindex_product(product)
    else
      Products::FilterValuesIndexer.new(category, parameters: parameters).reindex!
    end

    task&.mark_as_completed!(processed: 1, updated: 1)
  rescue StandardError => e
    Rails.logger.error "ReindexCategoryFiltersJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}"
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end
end
