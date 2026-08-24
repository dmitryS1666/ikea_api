# frozen_string_literal: true

class CollectProductDocumentStatsJob < ApplicationJob
  queue_as :parser

  REPORT_DIR = Rails.root.join("tmp", "product_document_stats").freeze
  CHECKPOINT_EVERY = 50

  def perform(limit: nil, task_id: nil, live: true)
    live = cast_bool(live, default: true)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("collect_product_document_stats", limit: limit, payload: { "live" => live })
    task.update!(processed: 0, created: 0, updated: 0, error_count: 0) if task.status == "pending"
    task.mark_as_running!

    notify_started("collect_product_document_stats", limit: limit)
    started_at = Time.current

    collector = Collector.new(live: live)
    scope = Product.order(:id)
    scope = scope.limit(limit.to_i) if limit.present? && limit.to_i.positive?

    scope.find_each(batch_size: 100) do |product|
      check_task_not_stopped!(task)
      collector.visit_product(product)
      task.increment_processed!
      task.increment_updated! if collector.last_had_documents
      collector.last_errors.times { task.increment_errors! }

      if (collector.products_checked % CHECKPOINT_EVERY).zero?
        task.update_payload!(collector.summary.merge("partial" => true, "live" => live))
      end
    end

    payload = collector.summary.merge(
      "partial" => false,
      "live" => live,
      "report_path" => write_report(task, collector)
    )
    task.update_payload!(payload)

    stats = {
      processed: collector.products_checked,
      created: collector.unique_sized_count,
      updated: collector.products_with_documents,
      errors: collector.error_count,
      duration: Time.current - started_at
    }
    task.mark_as_completed!(stats)
    notify_completed("collect_product_document_stats", stats)
    TelegramService.send_product_document_stats(payload)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    notify_error("collect_product_document_stats", e)
    raise
  end

  class Collector
    attr_reader :products_checked, :products_with_documents, :error_count, :last_had_documents, :last_errors

    def initialize(live:, size_fetcher: Products::RemoteContentLength, html_fetcher: Products::PipHtmlFetcher)
      @live = live
      @size_fetcher = size_fetcher
      @html_fetcher = html_fetcher
      @products_checked = 0
      @products_with_documents = 0
      @live_fetched = 0
      @error_count = 0
      @last_had_documents = false
      @last_errors = 0
      @size_cache = {}
      @url_meta = {}
      @product_bytes = 0
      @sample_skus = []
      @largest = []
    end

    def visit_product(product)
      @products_checked += 1
      @last_errors = 0
      urls = Products::DocumentUrlExtractor.urls_from_product(product)

      if @live && urls.empty? && product.url.present?
        html = @html_fetcher.fetch(product.url)
        @live_fetched += 1
        if html.present?
          urls |= Products::DocumentUrlExtractor.urls_from_html(html)
        else
          note_error
        end
      end

      @last_had_documents = urls.any?
      @products_with_documents += 1 if @last_had_documents

      product_total = 0
      urls.each do |url|
        bytes = cached_size(url, product)
        next unless bytes&.positive?

        product_total += bytes
        remember_largest(product, url, bytes)
      end
      @product_bytes += product_total

      if @last_had_documents && @sample_skus.size < 20
        @sample_skus << product.sku
      end
    end

    def unique_sized_count
      @size_cache.count { |_key, bytes| bytes.to_i.positive? }
    end

    def summary
      unique_bytes = @size_cache.values.compact.sum
      sized = @size_cache.values.compact
      {
        "metric" => "product_document_file_sizes",
        "products_checked" => @products_checked,
        "products_with_documents" => @products_with_documents,
        "unique_downloadable_urls" => @size_cache.size,
        "unique_sized_documents" => unique_sized_count,
        "size_unknown" => @size_cache.count { |_key, bytes| bytes.nil? || bytes.to_i <= 0 },
        "live_fetched" => @live_fetched,
        "unique_total_bytes" => unique_bytes,
        "unique_total_human" => self.class.human_bytes(unique_bytes),
        "product_total_bytes" => @product_bytes,
        "product_total_human" => self.class.human_bytes(@product_bytes),
        "avg_bytes" => sized.empty? ? 0 : (sized.sum / sized.size),
        "min_bytes" => sized.min || 0,
        "max_bytes" => sized.max || 0,
        "by_extension" => by_extension,
        "largest" => @largest,
        "sample_skus" => @sample_skus
      }
    end

    def self.human_bytes(bytes)
      CollectProductVideoStatsJob::Collector.human_bytes(bytes)
    end

    private

    def cached_size(url, product)
      key = Products::DocumentUrlExtractor.canonical_key(url)
      return @size_cache[key] if @size_cache.key?(key)

      bytes = @size_fetcher.fetch(url)
      note_error if bytes.nil?
      @size_cache[key] = bytes
      @url_meta[key] = {
        "url" => url,
        "extension" => Products::DocumentUrlExtractor.extension_for(url),
        "sku" => product.sku
      }
      bytes
    end

    def remember_largest(product, url, bytes)
      @largest << {
        "sku" => product.sku,
        "url" => url,
        "bytes" => bytes,
        "human" => self.class.human_bytes(bytes)
      }
      @largest.sort_by! { |row| -row["bytes"].to_i }
      @largest = @largest.first(20)
    end

    def by_extension
      grouped = Hash.new { |hash, key| hash[key] = { "count" => 0, "bytes" => 0 } }
      @size_cache.each do |key, bytes|
        ext = @url_meta.dig(key, "extension") || "unknown"
        grouped[ext]["count"] += 1
        grouped[ext]["bytes"] += bytes.to_i
      end
      grouped.transform_values do |row|
        row.merge("human" => self.class.human_bytes(row["bytes"]))
      end
    end

    def note_error
      @error_count += 1
      @last_errors += 1
    end
  end

  private

  def cast_bool(value, default:)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def write_report(task, collector)
    FileUtils.mkdir_p(REPORT_DIR)
    path = REPORT_DIR.join("#{task.id}.json")
    File.write(path, JSON.pretty_generate(collector.summary.merge("task_id" => task.id)))
    path.to_s
  rescue StandardError => e
    Rails.logger.warn("CollectProductDocumentStatsJob: report write failed: #{e.message}")
    nil
  end
end
