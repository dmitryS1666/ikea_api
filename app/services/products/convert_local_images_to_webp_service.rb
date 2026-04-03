# frozen_string_literal: true

require "uri"
require "json"
require "open3"
require "fileutils"
require "pathname"
require "set"

module Products
  class ConvertLocalImagesToWebpService
    SUPPORTED_EXTENSIONS = %w[.jpg .jpeg .png].freeze
    DEFAULT_BATCH_SIZE = 100
    DEFAULT_QUALITY = 82

    Result = Struct.new(
      :processed_products,
      :updated_products,
      :processed_images,
      :converted_images,
      :skipped_images,
      :deleted_originals,
      :error_skus,
      :skipped_skus,
      :errors,
      keyword_init: true
    )

    def initialize(scope: Product.all, dry_run: true, quality: DEFAULT_QUALITY, batch_size: DEFAULT_BATCH_SIZE, logger: nil)
      @scope = scope
      @dry_run = dry_run
      @quality = quality.to_i
      @batch_size = batch_size.to_i.positive? ? batch_size.to_i : DEFAULT_BATCH_SIZE
      @logger = logger || default_logger

      @result = Result.new(
        processed_products: 0,
        updated_products: 0,
        processed_images: 0,
        converted_images: 0,
        skipped_images: 0,
        deleted_originals: 0,
        error_skus: [],
        errors: [],
        skipped_skus: []
      )
    end

    def call
      ensure_cwebp_available!

      @scope.find_each(batch_size: @batch_size) do |product|
        process_product(product)
      rescue StandardError => e
        log_error(product, nil, e)
      end

      log_summary
      @result
    end

    private

    attr_reader :result

    def process_product(product)
      @result.processed_products += 1

      images = normalize_local_images(product.local_images)
      return if images.blank?

      changed = false
      new_images = []

      images.each do |image_path|
        begin
          new_path, changed_flag = process_image(product, image_path)
          new_images << new_path
          changed ||= changed_flag
        rescue StandardError => e
          log_error(product, image_path, e)
          new_images << image_path
        end
      end

      new_images = deduplicate_preserving_order(new_images)

      return unless changed
      return if new_images == images

      if @dry_run
        log("[DRY RUN] product sku=#{product.sku} id=#{product.id} will be updated")
      else
        product.update_columns(
          local_images: new_images.to_json,
          updated_at: Time.current
        )
      end

      @result.updated_products += 1
    end

    def process_image(product, image_path)
      @result.processed_images += 1

      if image_path.to_s.downcase.end_with?(".webp")
        @result.skipped_images += 1
        @result.skipped_skus << product.sku
        log("SKIP already webp sku=#{product.sku} path=#{image_path}")
        return [image_path, false]
      end

      source = absolute_path(image_path)
      log("CHECK sku=#{product.sku} path=#{image_path} source=#{source}")

      unless source.present? && File.exist?(source)
        @result.skipped_images += 1
        @result.skipped_skus << product.sku
        log("SKIP missing file sku=#{product.sku} path=#{image_path} source=#{source}")
        return [image_path, false]
      end

      ext = File.extname(source).downcase
      unless SUPPORTED_EXTENSIONS.include?(ext)
        @result.skipped_images += 1
        @result.skipped_skus << product.sku
        log("SKIP unsupported extension sku=#{product.sku} path=#{image_path} ext=#{ext}")
        return [image_path, false]
      end

      target = source.sub(/\.(jpg|jpeg|png)\z/i, ".webp")
      relative_target = relative_path(target, image_path)

      if File.exist?(target) && File.size?(target)
        log("TARGET EXISTS sku=#{product.sku} source=#{source} target=#{target}")

        unless @dry_run
          delete_original_if_safe(source, target, product)
        end

        return [relative_target, image_path != relative_target]
      end

      if File.exist?(target) && !File.size?(target)
        log("REMOVE BROKEN TARGET sku=#{product.sku} target=#{target}")
        File.delete(target)
      end

      if @dry_run
        log("[DRY RUN] CONVERT sku=#{product.sku} #{image_path} -> #{relative_target}")
        @result.converted_images += 1
        return [relative_target, true]
      end

      convert_to_webp!(source, target)

      unless File.exist?(target) && File.size?(target)
        raise "WEBP file was not created or is empty: #{target}"
      end

      delete_original_if_safe(source, target, product)

      @result.converted_images += 1
      log("OK sku=#{product.sku} #{image_path} -> #{relative_target}")

      [relative_target, true]
    end

    def convert_to_webp!(src, dst)
      FileUtils.mkdir_p(File.dirname(dst))

      cmd = [
        "cwebp",
        "-q", normalized_quality.to_s,
        "-m", "6",
        "-af",
        "-sharp_yuv",
        "-mt",
        src,
        "-o", dst
      ]

      stdout, stderr, status = Open3.capture3(*cmd)

      log("CWEBP CMD: #{cmd.join(' ')}")
      log("CWEBP STDOUT: #{stdout.strip}") if stdout.present?
      log("CWEBP STDERR: #{stderr.strip}") if stderr.present?

      return if status.success?

      begin
        File.delete(dst) if File.exist?(dst)
      rescue StandardError
        nil
      end

      raise "cwebp error: #{stderr.presence || stdout || 'unknown error'}"
    end

    def delete_original_if_safe(source, target, product)
      return unless File.exist?(source)
      return unless File.exist?(target) && File.size?(target)
      return if File.extname(source).downcase == ".webp"

      File.delete(source)
      @result.deleted_originals += 1
      log("DELETE ORIGINAL sku=#{product.sku} source=#{source}")
    end

    def absolute_path(path)
      raw = path.to_s.strip
      return nil if raw.blank?

      relative =
        begin
          uri = URI.parse(raw)
          uri.path.presence || raw
        rescue URI::InvalidURIError
          raw
        end

      cleaned = relative.sub(/\A\//, "")

      if cleaned.start_with?("images/", "uploads/")
        Rails.root.join("public", cleaned).to_s
      elsif cleaned.start_with?("storage/")
        Rails.root.join(cleaned).to_s
      else
        Rails.root.join(cleaned).to_s
      end
    end

    def relative_path(target, original)
      original_str = original.to_s

      new_path =
        if target.include?("/public/")
          Pathname.new(target).relative_path_from(Rails.root.join("public")).to_s
        else
          Pathname.new(target).relative_path_from(Rails.root).to_s
        end

      begin
        uri = URI.parse(original_str)
        if uri.scheme && uri.host
          uri.path = "/#{new_path}"
          uri.to_s
        else
          original_str.start_with?("/") ? "/#{new_path}" : new_path
        end
      rescue URI::InvalidURIError
        original_str.start_with?("/") ? "/#{new_path}" : new_path
      end
    end

    def normalize_local_images(value)
      case value
      when nil
        []
      when Array
        value.compact.map(&:to_s).map(&:strip).reject(&:blank?)
      when String
        stripped = value.strip
        return [] if stripped.blank?
    
        begin
          parsed = JSON.parse(stripped)
    
          case parsed
          when Array
            parsed.compact.map(&:to_s).map(&:strip).reject(&:blank?)
          when String
            [parsed.strip].reject(&:blank?)
          else
            [stripped]
          end
        rescue JSON::ParserError
          [stripped]
        end
      else
        Array(value).compact.map(&:to_s).map(&:strip).reject(&:blank?)
      end
    end

    def deduplicate_preserving_order(items)
      seen = Set.new

      items.each_with_object([]) do |item, acc|
        next if seen.include?(item)

        seen << item
        acc << item
      end
    end

    def ensure_cwebp_available!
      _stdout, _stderr, status = Open3.capture3("cwebp", "-version")
      return if status.success?

      raise "cwebp is not available. Install it first: sudo apt install webp"
    end

    def normalized_quality
      return 82 if @quality < 1
      return 100 if @quality > 100

      @quality
    end

    def default_logger
      log_path = Rails.root.join("log", "convert_local_images_to_webp.log")
      Logger.new(log_path, 10, 50.megabytes).tap do |logger|
        logger.level = Logger::INFO
      end
    end

    def log_summary
      if @result.skipped_skus.any?
        log("SKIPPED SKUS: #{@result.skipped_skus.uniq.join(', ')}")
      end
      log("SUMMARY processed_products=#{@result.processed_products} updated_products=#{@result.updated_products} processed_images=#{@result.processed_images} converted_images=#{@result.converted_images} skipped_images=#{@result.skipped_images} deleted_originals=#{@result.deleted_originals} errors_count=#{@result.errors.size}")
      log("ERROR SKUS: #{@result.error_skus.uniq.join(', ')}") if @result.error_skus.any?
    end

    def log(message)
      @logger.info(message)
    end

    def log_error(product, image_path, error)
      sku = product&.sku
      msg = "ERROR sku=#{sku} product_id=#{product&.id} path=#{image_path} error_class=#{error.class} error=#{error.message}"

      @result.errors << msg
      @result.error_skus << sku if sku.present?

      @logger.error(msg)
      @logger.error(error.backtrace.first(10).join("\n")) if error.backtrace.present?
    end
  end
end
