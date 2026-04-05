# lib/tasks/check_broken_local_images.rake
require "json"
require "shellwords"
require "fileutils"

namespace :products do
  desc "Проверка local_images: товары без картинок, битые картинки, общая статистика"
  task check_broken_local_images: :environment do
    dry_run    = ENV.fetch("DRY_RUN", "true") == "true"
    limit      = ENV["LIMIT"]&.to_i
    batch_size = ENV.fetch("BATCH_SIZE", "200").to_i
    log_every  = ENV.fetch("LOG_EVERY", "100").to_i

    log_dir = Rails.root.join("log")
    tmp_dir = Rails.root.join("tmp")
    FileUtils.mkdir_p(log_dir)
    FileUtils.mkdir_p(tmp_dir)

    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    log_file_path  = log_dir.join("check_broken_local_images_#{timestamp}.log")
    json_file_path = tmp_dir.join("check_broken_local_images_report_#{timestamp}.json")
    no_images_file_path = tmp_dir.join("products_without_images_#{timestamp}.txt")

    scope = Product.all
    scope = scope.limit(limit) if limit.present?

    total_products_checked        = 0
    total_products_without_images = 0
    total_products_with_broken    = 0
    total_products_all_ok         = 0

    total_images_declared         = 0
    total_broken_images           = 0
    total_valid_images            = 0

    products_without_images_skus  = []
    broken_products_details       = []
    broken_json_products          = []

    started_at = Time.current

    logger = lambda do |message|
      puts message
      File.open(log_file_path, "a") { |f| f.puts(message) }
    end

    logger.call("=== START products:check_broken_local_images ===")
    logger.call("DRY_RUN=#{dry_run}")
    logger.call("LIMIT=#{limit || 'ALL'}")
    logger.call("BATCH_SIZE=#{batch_size}")
    logger.call("LOG_EVERY=#{log_every}")
    logger.call("STARTED_AT=#{started_at}")
    logger.call("LOG_FILE=#{log_file_path}")
    logger.call("JSON_FILE=#{json_file_path}")
    logger.call("NO_IMAGES_FILE=#{no_images_file_path}")

    scope.find_in_batches(batch_size: batch_size).with_index do |products, batch_index|
      logger.call("--- batch #{batch_index + 1}, size=#{products.size} ---")

      products.each do |product|
        total_products_checked += 1

        raw_images = product.local_images

        paths =
          begin
            parsed =
              if raw_images.is_a?(String)
                raw_images.strip.presence ? JSON.parse(raw_images) : []
              elsif raw_images.is_a?(Array)
                raw_images
              else
                []
              end

            parsed.is_a?(Array) ? parsed.compact.map(&:to_s).map(&:strip).reject(&:blank?) : []
          rescue JSON::ParserError => e
            total_products_with_broken += 1
            total_broken_images += 1

            broken_json_products << {
              sku: product.sku,
              error: e.message,
              local_images_raw: raw_images
            }

            logger.call("BROKEN_JSON | sku=#{product.sku} | error=#{e.message}")
            next
          end

        if paths.empty?
          total_products_without_images += 1
          products_without_images_skus << product.sku
          logger.call("NO_IMAGES | sku=#{product.sku}")
          next
        end

        total_images_declared += paths.size

        broken_paths = []
        valid_paths = []

        paths.each do |path|
          normalized_path = path.start_with?("/") ? path : "/#{path}"
          full_path = Rails.root.join("public", normalized_path.sub(%r{\A/}, ""))

          unless File.exist?(full_path)
            broken_paths << normalized_path
            next
          end

          valid = system("identify #{Shellwords.escape(full_path.to_s)} > /dev/null 2>&1")

          if valid
            valid_paths << normalized_path
            total_valid_images += 1
          else
            broken_paths << normalized_path
          end
        end

        if broken_paths.any?
          total_products_with_broken += 1
          total_broken_images += broken_paths.size

          broken_products_details << {
            sku: product.sku,
            declared_images_count: paths.size,
            valid_images_count: valid_paths.size,
            broken_images_count: broken_paths.size,
            broken_paths: broken_paths
          }

          broken_paths.each do |broken_path|
            logger.call("BROKEN | sku=#{product.sku} | #{broken_path}")
          end

          unless dry_run
            product.update_columns(local_images: valid_paths.to_json)
            logger.call("UPDATED | sku=#{product.sku} | removed=#{broken_paths.size} | left=#{valid_paths.size}")
          end
        else
          total_products_all_ok += 1
        end

        if (total_products_checked % log_every).zero?
          elapsed = Time.current - started_at
          logger.call(
            "PROGRESS | checked=#{total_products_checked} | " \
            "without_images=#{total_products_without_images} | " \
            "broken_products=#{total_products_with_broken} | " \
            "all_ok=#{total_products_all_ok} | " \
            "declared_images=#{total_images_declared} | " \
            "valid_images=#{total_valid_images} | " \
            "broken_images=#{total_broken_images} | " \
            "elapsed=#{elapsed.round(2)}s"
          )
        end
      end
    end

    File.open(no_images_file_path, "w") do |f|
      products_without_images_skus.each { |sku| f.puts(sku) }
    end

    report = {
      started_at: started_at,
      finished_at: Time.current,
      elapsed_seconds: (Time.current - started_at).round(2),
      dry_run: dry_run,
      limit: limit,
      batch_size: batch_size,
      totals: {
        checked_products: total_products_checked,
        products_without_images: total_products_without_images,
        products_with_broken_images: total_products_with_broken,
        products_with_all_images_ok: total_products_all_ok,
        declared_images: total_images_declared,
        valid_images: total_valid_images,
        broken_images: total_broken_images
      },
      files: {
        log_file: log_file_path.to_s,
        json_file: json_file_path.to_s,
        no_images_file: no_images_file_path.to_s
      },
      products_without_images_skus: products_without_images_skus,
      broken_json_products: broken_json_products,
      broken_products_details: broken_products_details
    }

    File.write(json_file_path, JSON.pretty_generate(report))

    finished_at = Time.current
    elapsed = finished_at - started_at

    logger.call("=== FINISH products:check_broken_local_images ===")
    logger.call("checked_products=#{total_products_checked}")
    logger.call("products_without_images=#{total_products_without_images}")
    logger.call("products_with_broken_images=#{total_products_with_broken}")
    logger.call("products_with_all_images_ok=#{total_products_all_ok}")
    logger.call("declared_images=#{total_images_declared}")
    logger.call("valid_images=#{total_valid_images}")
    logger.call("broken_images=#{total_broken_images}")
    logger.call("started_at=#{started_at}")
    logger.call("finished_at=#{finished_at}")
    logger.call("elapsed=#{elapsed.round(2)}s")
    logger.call("NO_IMAGES_FILE=#{no_images_file_path}")
    logger.call("JSON_FILE=#{json_file_path}")
    logger.call("LOG_FILE=#{log_file_path}")
  end
end
