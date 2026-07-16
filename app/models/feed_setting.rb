require "cgi"
require "json"

class FeedSetting < ApplicationRecord
  enum feed_access_mode: { public: 0, token: 1 }, _suffix: :mode

  validates :base_url, :currency_default, presence: true
  validates :store_name, :store_company, :store_platform_brand, presence: true
  validates :feed_token, presence: true, if: :token_feed_access_mode?

  after_initialize :ensure_availability_mapping

  def self.instance
    first_or_create! do |setting|
      setting.base_url = "https://example.com"
      setting.store_name = "IKEA"
      setting.store_company = "IKEA"
      setting.store_platform_brand = "IKEA"
      setting.currency_default = "BYN"
    end
  end

  def availability_mapping_json
    JSON.pretty_generate(availability_mapping_hash)
  rescue JSON::GeneratorError
    availability_mapping.to_s
  end

  def availability_mapping_json=(value)
    self.availability_mapping = parse_json(value) || availability_mapping_hash
  end

  def availability_mapping_hash
    normalize_availability_values(availability_mapping.presence || default_availability_mapping)
  end

  def base_url_root
    base_url.to_s.chomp("/")
  end

  def token_query
    return "" unless token_mode? && feed_token.present?

    "?token=#{CGI.escape(feed_token)}"
  end

  def token_feed_access_mode?
    token_mode?
  end

  private

  def ensure_availability_mapping
    self.availability_mapping ||= default_availability_mapping
  end

  def default_availability_mapping
    {
      "in_stock" => "in_stock",
      "out_of_stock" => "out_of_stock",
      "preorder" => "preorder"
    }
  end

  def normalize_availability_values(hash)
    hash.to_h.transform_values do |value|
      case value.to_s.strip.downcase
      when "in stock" then "in_stock"
      when "out of stock" then "out_of_stock"
      else value
      end
    end
  end

  def parse_json(value)
    return value if value.blank?

    if value.is_a?(String)
      JSON.parse(value)
    else
      value
    end
  rescue JSON::ParserError
    value
  end
end
