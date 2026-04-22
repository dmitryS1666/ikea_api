# frozen_string_literal: true

class ImportProductsBySkusJob < ApplicationJob
  queue_as :parser

  def perform(task_id:, **_opts)
    task = ParserTask.find(task_id)
    payload = (task.payload || {}).stringify_keys
    skus = parse_skus(payload["skus"])

    if skus.empty?
      task.mark_as_failed!("No SKUs provided")
      return
    end

    task.update!(limit: skus.length)
    task.mark_as_running!

    notify_started("import_products_by_skus", limit: skus.length)
    started_at = Time.current

    stats = {
      processed: 0,
      created: 0,
      updated: 0,
      errors: 0,
      categorized: 0
    }

    skus.each do |sku|
      break if task_stopped?(task)

      begin
        check_task_not_stopped!(task)
        product, created = ensure_product!(sku)
        if created
          stats[:created] += 1
          task.increment_created!
        end

        ext = Products::ExtendedAttributesFetchService.fetch_for_product(product, force_ai_translation: true)
        if ext[:updated]
          stats[:updated] += 1
          task.increment_updated!
        end

        product.reload
        detected_category = Products::IkeaCategoryProbeService.detect(product)
        if detected_category.present? && product.time_ikea_id.to_s != detected_category.to_s
          product.update!(time_ikea_id: detected_category.to_s)
          stats[:categorized] += 1
        end

        stats[:processed] += 1
        task.increment_processed!
      rescue StandardError => e
        Rails.logger.error("ImportProductsBySkusJob sku=#{sku}: #{e.class} #{e.message}")
        stats[:errors] += 1
        task.increment_errors!
      end
    end

    task.mark_as_completed!(stats)
    stats[:duration] = Time.current - started_at
    notify_completed("import_products_by_skus", stats)
  rescue StandardError => e
    if e.message == "Task was stopped manually"
      Rails.logger.info "ImportProductsBySkusJob: task #{task_id} stopped manually"
      return
    end

    Rails.logger.error "ImportProductsBySkusJob error: #{e.message}\n#{e.backtrace&.first(12)&.join("\n")}"
    task&.mark_as_failed!(e.message)
    notify_error("import_products_by_skus", e)
  end

  private

  def parse_skus(raw)
    raw.to_s.split(/[\s,;\n\r\t]+/)
       .map { |s| Products::ListingSkuResolver.coerce_listing_identifier(s) }
       .compact
       .map(&:strip)
       .reject(&:blank?)
       .uniq
  end

  def ensure_product!(sku)
    existing = Products::ListingSkuResolver.find_product(sku)
    return [existing, false] if existing

    article = sku.to_s.match(/(\d{8})/)&.captures&.first
    product = Product.create!(
      sku: sku,
      item_no: article,
      name: "IKEA #{sku}",
      price: 0,
      quantity: 0,
      url: "https://www.ikea.com/pl/pl/p/-#{article || sku}/"
    )
    [product, true]
  end
end
