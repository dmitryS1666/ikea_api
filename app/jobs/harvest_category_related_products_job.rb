# frozen_string_literal: true

# Собирает общий related_products для выбранной категории:
# - берет 1-й и последний товар листинга PL,
# - тянет related + аксессуары с карточек,
# - сохраняет в CategoryRelatedProductList.
class HarvestCategoryRelatedProductsJob < ApplicationJob
  queue_as :parser

  def perform(ikea_id:, task_id: nil)
    task =
      if task_id.present?
        ParserTask.find(task_id)
      else
        create_parser_task("harvest_category_related_products", limit: nil)
      end

    payload = (task.payload || {}).stringify_keys
    ikea_id = payload["ikea_id"].presence || ikea_id.to_s

    category = Category.find_by(ikea_id: ikea_id.to_s)
    unless category
      msg = "Категория не найдена: ikea_id=#{ikea_id}"
      task.mark_as_failed!(msg)
      notify_error("harvest_category_related_products", StandardError.new(msg))
      return
    end

    task.mark_as_running!
    notify_started("harvest_category_related_products", limit: nil)
    started_at = Time.current

    stats = {
      processed: 0,
      created: 0,
      updated: 0,
      errors: 0
    }

    begin
      rows = fetch_listing_rows(category, task)
      if rows.empty?
        msg = "Пустой листинг категории ikea_id=#{category.ikea_id}"
        task.mark_as_failed!(msg)
        notify_error("harvest_category_related_products", StandardError.new(msg))
        return
      end

      before = CategoryRelatedProductList.find_by(category_id: category.ikea_id.to_s)
      before_count = Array(before&.related_products).size

      Products::CategoryRelatedProductsHarvestService.call(category: category, listing_rows: rows)

      after = CategoryRelatedProductList.find_by(category_id: category.ikea_id.to_s)
      after_count = Array(after&.related_products).size

      stats[:processed] = rows.size
      stats[:updated] = 1
      stats[:related_products_count] = after_count
      stats[:related_products_diff] = after_count - before_count
      stats[:anchor_first_sku] = after&.anchor_first_sku
      stats[:anchor_last_sku] = after&.anchor_last_sku
      stats[:duration] = Time.current - started_at

      task.mark_as_completed!(stats)
      notify_completed("harvest_category_related_products", stats)
    rescue StandardError => e
      Rails.logger.error "HarvestCategoryRelatedProductsJob: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error("harvest_category_related_products", e)
    end
  end

  private

  def fetch_listing_rows(category, task)
    rows = []
    offset = 0
    limit = 50

    loop do
      check_task_not_stopped!(task)
      chunk = CategoryLtListingService.fetch_page(category, offset: offset, limit: limit)
      break if chunk.empty?

      rows.concat(chunk)
      offset += limit
      break if chunk.size < limit
    end

    rows
  end
end
