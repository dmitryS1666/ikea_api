# frozen_string_literal: true

require "open3"
require "fileutils"

module Products
  class GenerateImagePreviewService
    DEFAULT_MAX_WIDTH = ENV.fetch("WEBP_PREVIEW_MAX_WIDTH", "300").to_i
    DEFAULT_QUALITY = ENV.fetch("WEBP_PREVIEW_QUALITY", "75").to_i
    DEFAULT_MAX_BYTES = ENV.fetch("WEBP_PREVIEW_MAX_BYTES", "20480").to_i

    Result = Struct.new(:generated, :skipped, :error, keyword_init: true)

    def initialize(source_path:, max_width: DEFAULT_MAX_WIDTH, quality: DEFAULT_QUALITY, max_bytes: DEFAULT_MAX_BYTES, force: false, logger: nil)
      @source_path = resolve_absolute(source_path)
      @max_width = [max_width.to_i, 1].max
      @quality = quality.to_i.clamp(1, 100)
      @max_bytes = [max_bytes.to_i, 1].max
      @force = force
      @logger = logger
    end

    def call
      return skip_result("missing source") unless @source_path.present? && File.file?(@source_path)

      rel = relative_public_path(@source_path)
      return skip_result("not a local product image") unless rel.present?

      preview_rel = ProductLocalImages.preview_rel_path(rel)
      preview_abs = Rails.public_path.join(preview_rel.delete_prefix("/")).to_s

      unless @force
        return skip_result("preview up to date") if preview_fresh?(@source_path, preview_abs)
      end

      generate_preview!(@source_path, preview_abs)
      Result.new(generated: true, skipped: false, error: nil)
    rescue StandardError => e
      log("ERROR #{@source_path}: #{e.class} #{e.message}")
      Result.new(generated: false, skipped: false, error: e.message)
    end

    private

    def generate_preview!(source_abs, preview_abs)
      ensure_cwebp_available!
      FileUtils.mkdir_p(File.dirname(preview_abs))

      width = @max_width
      quality = @quality

      3.times do
        run_cwebp!(source_abs, preview_abs, width: width, quality: quality)
        size = File.size(preview_abs)
        break if size <= @max_bytes

        quality -= 10
        width = (width * 0.85).to_i
        break if quality < 30 || width < 120
      end

      unless File.exist?(preview_abs) && File.size(preview_abs).positive?
        raise "preview file was not created: #{preview_abs}"
      end

      log("OK #{source_abs} -> #{preview_abs} (#{File.size(preview_abs)} bytes)")
    end

    def run_cwebp!(source_abs, preview_abs, width:, quality:)
      cmd = [
        "cwebp",
        "-q", quality.to_s,
        "-resize", width.to_s, "0",
        "-m", "6",
        "-mt",
        source_abs,
        "-o", preview_abs
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      return if status.success?

      FileUtils.rm_f(preview_abs)
      raise "cwebp error: #{stderr.presence || 'unknown error'}"
    end

    def preview_fresh?(source_abs, preview_abs)
      return false unless File.exist?(preview_abs) && File.size(preview_abs).positive?

      File.mtime(preview_abs) >= File.mtime(source_abs)
    end

    def resolve_absolute(path)
      raw = path.to_s.strip
      return nil if raw.blank?
      return raw if File.file?(raw)

      ProductLocalImages.public_abs_path(raw)
    end

    def relative_public_path(abs_path)
      public_root = Rails.public_path.to_s
      return nil unless abs_path.start_with?(public_root)

      normalize_rel_path(abs_path.delete_prefix(public_root))
    end

    def normalize_rel_path(path)
      ProductLocalImages.normalize_rel_path(path)
    end

    def ensure_cwebp_available!
      _stdout, _stderr, status = Open3.capture3("cwebp", "-version")
      return if status.success?

      raise "cwebp is not available. Install it first: sudo apt install webp"
    end

    def skip_result(reason)
      log("SKIP #{@source_path}: #{reason}")
      Result.new(generated: false, skipped: true, error: nil)
    end

    def log(message)
      @logger ? @logger.info(message) : Rails.logger.info("[GenerateImagePreviewService] #{message}")
    end
  end
end
