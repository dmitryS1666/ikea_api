# frozen_string_literal: true

# Полная актуализация одного товара по SKU (PL + LT fallback), с переиспользованием
# пайплайна из RefreshCategoryFromLtJob: enrich, variants, included/related, local images.
class RefreshProductFromLtJob < ApplicationJob
  queue_as :parser

  def perform(sku: nil, task_id: nil)
    task =
      if task_id.present?
        ParserTask.find(task_id)
      else
        create_parser_task("refresh_product_lt", limit: 1)
      end

    payload = (task.payload || {}).stringify_keys
    raw_sku = payload["sku"].presence || sku
    normalized_sku = Products::ListingSkuResolver.coerce_listing_identifier(raw_sku)
    category_ikea_id = payload["category_ikea_id"].to_s.strip.presence
    lt_jsonl_path = payload["lt_jsonl_path"].to_s.strip.presence
    process_related = ActiveModel::Type::Boolean.new.cast(payload["process_related"])

    if normalized_sku.blank?
      msg = "Не указан SKU товара"
      task.mark_as_failed!(msg)
      notify_error("refresh_product_lt", StandardError.new(msg))
      return
    end

    task.update!(limit: 1) if task.limit != 1
    check_task_not_stopped!(task)
    task.mark_as_running!
    notify_started("refresh_product_lt", limit: 1)
    started = Time.current

    stats = {
      processed: 0,
      created: 0,
      updated: 0,
      errors: 0,
      images_synced: 0,
      related_skus: [],
      missing_related_skus: []
    }

    helper = RefreshCategoryFromLtJob.new
    parser = ParseProductsJob.new

    begin
      check_task_not_stopped!(task)

      product = Products::ListingSkuResolver.find_product(normalized_sku)
      category = resolve_category_for_refresh(product, category_ikea_id)

      listing_row = fetch_listing_row_for_sku(category, normalized_sku) if category.present?
      canonical_sku = normalized_sku

      if listing_row.present? && category.present?
        before_processed = task.processed.to_i
        parsed_sku = helper.send(:process_one_listing_item, listing_row, parser, category, {}, task, stats, nil)
        canonical_sku = parsed_sku.presence || canonical_sku
        # Если ParseProductsJob не изменил запись, он не увеличивает processed.
        if task.processed.to_i == before_processed
          stats[:processed] += 1
          task.increment_processed!
        end
      end

      product = Products::ListingSkuResolver.find_product(canonical_sku) || product
      product, created = ensure_minimal_product!(product, canonical_sku)
      if created
        stats[:created] += 1
        task.increment_created!
      end

      category ||= resolve_category_for_refresh(product, category_ikea_id)
      unless category
        raise StandardError, "Не удалось определить категорию для SKU #{canonical_sku}. Передайте category_ikea_id в extra_data."
      end

      rows_by_sku = helper.send(:load_lt_jsonl_index, lt_jsonl_path)
      helper.send(:enrich_product!, product, category, rows_by_sku, task, stats, nil, process_related: process_related)

      stats[:processed] += 1 if stats[:processed].zero?
      task.increment_processed! if task.processed.to_i.zero?

      stats[:duration] = Time.current - started
      stats[:related_skus] = stats[:related_skus].uniq.sort
      stats[:related_skus_count] = stats[:related_skus].size
      stats[:missing_related_skus] = stats[:missing_related_skus].uniq.sort
      stats[:missing_related_skus_count] = stats[:missing_related_skus].size

      task.update_payload!(
        "sku" => canonical_sku,
        "resolved_category_ikea_id" => category.ikea_id.to_s
      )
      task.mark_as_completed!(stats)
      notify_completed("refresh_product_lt", stats)
    rescue StandardError => e
      if e.message == "Task was stopped manually"
        Rails.logger.info "RefreshProductFromLtJob: task #{task.id} stopped manually"
        return
      end

      Rails.logger.error "RefreshProductFromLtJob sku=#{normalized_sku}: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
      task.mark_as_failed!(e.message)
      notify_error("refresh_product_lt", e)
    end
  end

  private

  def fetch_listing_row_for_sku(category, sku)
    return nil if category.blank? || sku.blank?

    aliases = Products::ListingSkuResolver.aliases(sku).map(&:to_s).to_set
    offset = 0
    page_size = 50

    loop do
      rows = CategoryLtListingService.fetch_page(category, offset: offset, limit: page_size)
      break if rows.blank?

      found = rows.find do |row|
        row_sku =
          Products::ListingSkuResolver.coerce_listing_identifier(
            row["sku"] || row[:sku] || row["id"] || row[:id]
          )
        row_sku.present? && aliases.include?(row_sku.to_s)
      end
      return found if found

      break if rows.length < page_size
      offset += page_size
    end

    nil
  rescue StandardError => e
    Rails.logger.warn "RefreshProductFromLtJob: listing fetch failed category=#{category&.ikea_id} sku=#{sku}: #{e.message}"
    nil
  end

  def ensure_minimal_product!(product, sku)
    return [product, false] if product.present?

    article = sku.to_s.match(/(\d{8})/)&.captures&.first
    created = Product.create!(
      sku: sku.to_s,
      item_no: article,
      name: "IKEA #{sku}",
      price: 0,
      quantity: 0,
      url: "https://www.ikea.com/pl/pl/p/-#{article || sku}/"
    )
    [created, true]
  end

  def resolve_category_for_refresh(product, explicit_category_id)
    if explicit_category_id.present?
      category = Category.find_by(ikea_id: explicit_category_id.to_s)
      return category if category
    end

    category = product&.primary_category
    return category if category

    detected = Products::IkeaCategoryProbeService.detect(product) if product
    return Category.find_by(ikea_id: detected.to_s) if detected.present?

    nil
  end
end
