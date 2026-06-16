require "mini_magick"
require "tempfile"

module Images
  class WebpOptimizer
    TARGET_MAX_BYTES = 200.kilobytes
    QUALITY_STEPS = [88, 82, 76, 70, 64, 58, 52, 46, 40, 34].freeze
    SCALE_STEPS = [1.0, 0.92, 0.84, 0.76, 0.68, 0.6, 0.52, 0.44].freeze

    class << self
      def optimize_attachable(attachable, max_bytes: TARGET_MAX_BYTES)
        return nil unless attachable.respond_to?(:content_type)
        return nil unless raster_content_type?(attachable.content_type)

        source_path = attachable.respond_to?(:path) ? attachable.path : nil
        return nil if source_path.blank? || !File.exist?(source_path)

        optimize_from_path(
          source_path: source_path,
          original_filename: extract_filename(attachable),
          content_type: attachable.content_type,
          max_bytes: max_bytes
        )
      rescue => e
        Rails.logger.warn("Images::WebpOptimizer.optimize_attachable failed: #{e.class} #{e.message}")
        nil
      end

      def optimize_blob(blob, max_bytes: TARGET_MAX_BYTES)
        return blob unless blob
        return blob unless raster_content_type?(blob.content_type)
        return blob if blob.content_type == "image/webp" && blob.byte_size.to_i <= max_bytes

        optimized = nil
        blob.open do |tmp_file|
          optimized = optimize_from_path(
            source_path: tmp_file.path,
            original_filename: blob.filename.to_s,
            content_type: blob.content_type,
            max_bytes: max_bytes
          )
        end
        return blob unless optimized

        ActiveStorage::Blob.create_and_upload!(
          io: optimized[:io],
          filename: optimized[:filename],
          content_type: optimized[:content_type]
        )
      ensure
        cleanup_io(optimized&.dig(:io))
      end

      private

      def optimize_from_path(source_path:, original_filename:, content_type:, max_bytes:)
        return nil unless raster_content_type?(content_type)
        if content_type == "image/webp" && File.size(source_path).to_i <= max_bytes
          return nil
        end

        dimensions = source_dimensions(source_path)
        return nil unless dimensions

        best_candidate = nil
        best_size = Float::INFINITY

        SCALE_STEPS.each do |scale|
          target_width = [(dimensions[:width] * scale).round, 1].max
          target_height = [(dimensions[:height] * scale).round, 1].max

          QUALITY_STEPS.each do |quality|
            candidate = encode_webp(
              source_path: source_path,
              target_width: target_width,
              target_height: target_height,
              quality: quality
            )
            next unless candidate

            current_size = File.size(candidate.path).to_i
            if current_size <= max_bytes
              cleanup_io(best_candidate)
              return build_result(candidate, original_filename)
            end

            if current_size < best_size
              cleanup_io(best_candidate)
              best_candidate = candidate
              best_size = current_size
            else
              cleanup_io(candidate)
            end
          end
        end

        build_result(best_candidate, original_filename)
      end

      def encode_webp(source_path:, target_width:, target_height:, quality:)
        image = MiniMagick::Image.open(source_path)
        image.auto_orient
        image.strip
        image.resize("#{target_width}x#{target_height}>")
        image.format("webp")
        image.quality(quality.to_s)

        tmp = Tempfile.new(["optimized_admin_image", ".webp"])
        tmp.binmode
        image.write(tmp.path)
        tmp.rewind
        tmp
      rescue => e
        Rails.logger.warn("Images::WebpOptimizer.encode_webp failed: #{e.class} #{e.message}")
        nil
      end

      def source_dimensions(path)
        image = MiniMagick::Image.open(path)
        { width: image.width.to_i, height: image.height.to_i }
      rescue => e
        Rails.logger.warn("Images::WebpOptimizer.source_dimensions failed: #{e.class} #{e.message}")
        nil
      end

      def build_result(io, original_filename)
        return nil unless io

        base_name = File.basename(original_filename.to_s, ".*").presence || "image"
        {
          io: io,
          filename: "#{base_name}.webp",
          content_type: "image/webp"
        }
      end

      def raster_content_type?(content_type)
        type = content_type.to_s.downcase
        return false unless type.start_with?("image/")
        return false if type == "image/svg+xml"
        return false if type == "image/gif"

        true
      end

      def extract_filename(attachable)
        if attachable.respond_to?(:original_filename)
          attachable.original_filename
        elsif attachable.respond_to?(:filename)
          attachable.filename.to_s
        else
          "image"
        end
      end

      def cleanup_io(io)
        return unless io

        io.close unless io.closed?
        io.unlink if io.respond_to?(:unlink)
      rescue => e
        Rails.logger.debug("Images::WebpOptimizer.cleanup_io failed: #{e.class} #{e.message}")
      end
    end
  end
end
