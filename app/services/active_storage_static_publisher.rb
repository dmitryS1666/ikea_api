# frozen_string_literal: true

# Publishes ActiveStorage blobs into public/images/cms so Nginx can serve them
# without going through Puma (same path as product /images/*).
module ActiveStorageStaticPublisher
  PREFIX = "images/cms"

  module_function

  def url_for(attachment)
    return nil unless attachment&.attached?

    blob = attachment.blob
    relative = relative_path_for(blob)
    publish!(blob, relative)
    "/#{relative}"
  rescue StandardError => e
    Rails.logger.warn("[ActiveStorageStaticPublisher] #{e.class}: #{e.message}")
    fallback_blob_url(attachment)
  end

  def relative_path_for(blob)
    ext = File.extname(blob.filename.to_s)
    ext = "" if ext.length > 12
    key = blob.key.to_s
    "#{PREFIX}/#{key[0, 2]}/#{key[2, 2]}/#{key}#{ext}"
  end

  def publish!(blob, relative = nil)
    relative ||= relative_path_for(blob)
    dest = Rails.public_path.join(relative)
    return relative if dest.exist?

    src = blob.service.path_for(blob.key)
    raise "missing ActiveStorage file: #{src}" unless File.exist?(src)

    FileUtils.mkdir_p(dest.dirname)
    begin
      File.link(src, dest.to_s)
    rescue Errno::EXDEV, Errno::EPERM, Errno::EEXIST
      FileUtils.cp(src, dest) unless dest.exist?
    end
    relative
  end

  def fallback_blob_url(attachment)
    Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true)
  end

  def publish_all_cms!
    count = 0

    HomeBanner.find_each do |banner|
      next unless banner.image.attached?

      publish!(banner.image.blob)
      count += 1
    end

    Category.find_each do |category|
      %i[icon pictogram background_image].each do |name|
        attachment = category.public_send(name)
        next unless attachment.attached?

        publish!(attachment.blob)
        count += 1
      end
    end

    count
  end
end
