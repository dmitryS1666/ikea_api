require 'cgi'
require 'digest/md5'

class WebpayGetTransactionService
  Result = Struct.new(:ok, :fields, :raw_xml, :error, keyword_init: true)

  class << self
    def fetch(transaction_id)
      new.fetch(transaction_id)
    end

    def billing_configured?
      cfg = Rails.application.config.x.webpay
      cfg.billing_username.present? && cfg.billing_password.present?
    end
  end

  def fetch(transaction_id)
    return Result.new(ok: false, fields: {}, raw_xml: nil, error: 'transaction_id_blank') if transaction_id.blank?
    return Result.new(ok: false, fields: {}, raw_xml: nil, error: 'billing_not_configured') unless self.class.billing_configured?

    xml = build_request_xml(transaction_id)
    url = billing_url
    body = "*API=&API_XML_REQUEST=#{CGI.escape(xml)}"

    response = HTTParty.post(
      url,
      body: body,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
      timeout: 30
    )

    unless response.success?
      return Result.new(ok: false, fields: {}, raw_xml: response.body, error: "http_#{response.code}")
    end

    doc = Nokogiri::XML(response.body)
    err_text = doc.at_xpath('//error')&.text&.strip || doc.at_xpath('//*[local-name()="error"]')&.text&.strip

    fields = parse_response_fields(response.body)
    if fields.blank?
      msg = err_text.presence || 'empty_response'
      return Result.new(ok: false, fields: {}, raw_xml: response.body, error: msg)
    end

    Result.new(ok: true, fields: fields, raw_xml: response.body, error: nil)
  rescue StandardError => e
    Rails.logger.error("[WebpayGetTransaction] #{e.class}: #{e.message}")
    Result.new(ok: false, fields: {}, raw_xml: nil, error: e.message)
  end

  private

  def billing_url
    Rails.application.config.x.webpay.billing_api_url.to_s.chomp('/')
  end

  def build_request_xml(transaction_id)
    cfg = Rails.application.config.x.webpay
    password_md5 = Digest::MD5.hexdigest(cfg.billing_password)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <wsb_api_request>
        <command>get_transaction</command>
        <authorization>
          <username>#{escape_xml(cfg.billing_username)}</username>
          <password>#{password_md5}</password>
        </authorization>
        <fields>
          <transaction_id>#{escape_xml(transaction_id.to_s)}</transaction_id>
        </fields>
      </wsb_api_request>
    XML
  end

  def escape_xml(str)
    str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;').gsub("'", '&apos;')
  end

  def parse_response_fields(xml_body)
    doc = Nokogiri::XML(xml_body)
    fields_el = doc.at_xpath('//fields') || doc.at_xpath('//*[local-name()="fields"]')
    h = {}
    if fields_el
      fields_el.element_children.each do |node|
        h[node.name.to_s.downcase] = node.text.to_s.strip
      end
      return h if h.present?
    end

    %w[transaction_id batch_timestamp currency_id amount payment_method payment_type order_id rrn wsb_signature].each do |name|
      n = doc.at_xpath("//#{name}") || doc.at_xpath("//*[local-name()='#{name}']")
      h[name] = n.text.to_s.strip if n
    end
    h
  end
end
