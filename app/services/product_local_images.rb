# frozen_string_literal: true

require "digest/sha1"
require "fileutils"

# Ссылки на локальные картинки товара в ActiveStorage (диск storage/).
# В БД в JSON local_images храним компактные ref: "as:<signed_id>".
# В API отдаём те же пути, что и для файлов в public: /images/products/aa/bb/cc/<sha1>.webp
# (как ImageStorage::Local), с зеркалированием блоба на диск при первом раскрытии/загрузке.
module ProductLocalImages
  AS_PREFIX = "as:".freeze
  PREVIEW_SUFFIX = "_preview".freeze
  LOCAL_PRODUCT_IMAGE_RE = %r{\A/images/products/}i
  PROD_IMG_FILENAME_RE = /\Aprod_img_([a-f0-9]{40})(\.[a-z0-9]+)\z/i

  module_function

  def blob_ref?(ref)
    ref.to_s.start_with?(AS_PREFIX)
  end

  def encode_ref(blob)
    "#{AS_PREFIX}#{blob.signed_id}"
  end

  def blob_from_ref(ref)
    return nil unless blob_ref?(ref)

    ActiveStorage::Blob.find_signed(ref.delete_prefix(AS_PREFIX))
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def ref_healthy?(ref)
    blob = blob_from_ref(ref)
    blob.present? && blob.service.exist?(blob.key)
  rescue StandardError
    false
  end

  # Путь как в эталонном API: /images/products/da/2d/9d/<sha1>.ext (sha1 из имени prod_img_<sha1>.webp)
  def etalon_rel_path_from_blob_filename(filename)
    m = filename.to_s.match(PROD_IMG_FILENAME_RE)
    return nil unless m

    hash = m[1].downcase
    ext = m[2].downcase
    a = hash[0..1]
    b = hash[2..3]
    c = hash[4..5]
    "/images/products/#{a}/#{b}/#{c}/#{hash}#{ext}"
  end

  def ensure_etalon_mirror!(blob)
    rel = etalon_rel_path_from_blob_filename(blob.filename.to_s)
    return if rel.blank?

    abs_path = Rails.root.join("public", rel.delete_prefix("/"))
    return if File.exist?(abs_path) && File.size(abs_path).to_i.positive?

    FileUtils.mkdir_p(File.dirname(abs_path))
    blob.open do |io|
      File.binwrite(abs_path, io.read)
    end

    ensure_preview_for_rel!(rel)
  rescue StandardError => e
    Rails.logger.warn("ProductLocalImages: ensure_etalon_mirror! failed: #{e.class} #{e.message}")
  end

  def preview_rel_path(full_path)
    path = normalize_rel_path(full_path)
    return path if path.blank?
    return path unless local_product_image_path?(path)
    return path if preview_path?(path)

    dir = File.dirname(path)
    base = File.basename(path).sub(/\.webp\z/i, "")
    base = base.sub(/#{PREVIEW_SUFFIX}\z/i, "")
    normalize_rel_path("#{dir}/#{base}#{PREVIEW_SUFFIX}.webp")
  end

  def preview_path?(path)
    path.to_s.match?(/#{PREVIEW_SUFFIX}\.webp\z/i)
  end

  def normalize_rel_path(path)
    raw = path.to_s.strip
    return raw if raw.blank?

    "/#{raw.delete_prefix('/')}".gsub(%r{/+}, "/")
  end

  def local_product_image_path?(path)
    normalize_rel_path(path).match?(LOCAL_PRODUCT_IMAGE_RE)
  end

  def preview_file_exists?(rel_path)
    abs = public_abs_path(rel_path)
    abs.present? && File.file?(abs) && File.size(abs).positive?
  end

  def preview_path_or_fallback(full_path)
    path = full_path.to_s.strip
    return path if path.blank?
    return path unless local_product_image_path?(path)
    return path if preview_path?(path)

    preview = preview_rel_path(path)
    preview_file_exists?(preview) ? preview : path
  end

  def preview_paths(value)
    expand_paths(value).map { |path| preview_path_or_fallback(path) }
  end

  def ensure_preview_for_rel!(rel_path)
    return unless local_product_image_path?(rel_path)

    Products::GenerateImagePreviewService.new(source_path: rel_path).call
  rescue StandardError => e
    Rails.logger.warn("ProductLocalImages: ensure_preview_for_rel! failed: #{e.class} #{e.message}")
    nil
  end

  def public_abs_path(rel_path)
    raw = rel_path.to_s.strip.delete_prefix("/")
    return nil if raw.blank?

    abs = Rails.public_path.join(raw)
    abs.to_s if File.exist?(abs)
  end

  def expand_path(ref)
    s = ref.to_s.strip
    return s if s.blank?
    return etalon_path_for_blob_ref(s) if blob_ref?(s)

    s
  rescue StandardError
    nil
  end

  def etalon_path_for_blob_ref(ref)
    blob = blob_from_ref(ref)
    return nil unless blob

    etalon = etalon_rel_path_from_blob_filename(blob.filename.to_s)
    if etalon.present?
      ensure_etalon_mirror!(blob)
      return etalon if File.exist?(Rails.root.join("public", etalon.delete_prefix("/")))
    end

    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true, disposition: :inline)
  rescue StandardError
    nil
  end

  # Убрать внешние URL IKEA из списка, если уже есть локальные /images/ или /uploads/
  def strip_remote_when_local_present(paths)
    arr = Array(paths).map(&:to_s).map(&:strip).reject(&:blank?)
    return arr if arr.empty?

    locals = arr.any? { |p| p.match?(%r{\A/(images|uploads)/}i) }
    return arr unless locals

    arr.reject { |p| p.match?(%r{\Ahttps?://}i) }
  end

  def expand_paths(value)
    arr =
      case value
      when nil
        []
      when String
        stripped = value.strip
        return [] if stripped.blank?

        begin
          parsed = JSON.parse(stripped)
          parsed.is_a?(Array) ? parsed : [parsed]
        rescue JSON::ParserError
          [stripped]
        end
      else
        Array(value)
      end

    out =
      arr.map(&:to_s).map(&:strip).reject(&:blank?).filter_map do |p|
        expanded = expand_path(p)
        next expanded if expanded.present?

        next p unless blob_ref?(p)

        nil
      end

    strip_remote_when_local_present(out)
  end

  # Для variants_payload: раскрыть as:, привести к эталонным путям, убрать ikea.com при наличии локальных
  def normalize_api_image_array(value)
    strip_remote_when_local_present(expand_paths(value))
  end

  def deterministic_base_filename(url)
    "prod_img_#{Digest::SHA1.hexdigest(url.to_s)}"
  end

  def find_existing_blob_for_url(url)
    base = deterministic_base_filename(url)
    %w[webp jpg jpeg png].each do |ext|
      b = ActiveStorage::Blob.find_by(filename: "#{base}.#{ext}")
      return b if b&.service&.exist?(b.key)
    end
    nil
  end

  def purge_ref!(ref)
    blob = blob_from_ref(ref)
    blob&.purge
  rescue StandardError
    nil
  end
end
