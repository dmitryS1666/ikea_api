require 'net/http'
require 'uri'
require 'fileutils'
require 'digest/sha1'

class DocumentDownloader
  STORAGE_PATH = Rails.root.join('public', 'documents').freeze

  def self.download(url, product_sku: nil)
    return nil if url.blank?

    # Генерируем имя файла на основе URL
    hash = Digest::SHA1.hexdigest(url)
    ext = File.extname(URI.parse(url).path)
    ext = '.pdf' if ext.blank?
    
    filename = product_sku ? "#{product_sku}_#{hash}#{ext}" : "#{hash}#{ext}"
    rel_path = "documents/#{filename}"
    abs_path = Rails.root.join('public', rel_path)

    return "/#{rel_path}" if File.exist?(abs_path)

    FileUtils.mkdir_p(STORAGE_PATH)

    begin
      ProxyRotator.with_proxy_retry do |proxy_options|
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 30

        if proxy_options && proxy_options[:http_proxyaddr]
          http.proxy_from_env = false
          http.proxy_address = proxy_options[:http_proxyaddr]
          http.proxy_port = proxy_options[:http_proxyport]
          http.proxy_user = proxy_options[:http_proxyuser]
          http.proxy_pass = proxy_options[:http_proxypass]
        end

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = ENV.fetch('USER_AGENT', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          File.binwrite(abs_path, response.body)
          return "/#{rel_path}"
        else
          Rails.logger.error "DocumentDownloader: Failed to download #{url}, code: #{response.code}"
          nil
        end
      end
    rescue => e
      Rails.logger.error "DocumentDownloader: Error downloading #{url}: #{e.message}"
      nil
    end
  end
end
