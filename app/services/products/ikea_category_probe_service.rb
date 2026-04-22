# frozen_string_literal: true
require "set"

module Products
  # Определяет ikea category id для товара по его PIP-странице.
  # Сохраняем именно "сырой" id с ikea.com во временное поле time_ikea_id;
  # дальше можно отдельно матчить его на локальные Category.
  class IkeaCategoryProbeService
    CATEGORY_ID_PATTERN = /\A\d{3,}\z/.freeze

    def self.detect(product)
      new(product).detect
    end

    def initialize(product)
      @product = product
    end

    def detect
      url = pl_product_url
      return nil if url.blank?

      html = IkeaApiService.fetch_product_details(url)
      return nil if html.blank?

      doc = Nokogiri::HTML(html)
      candidates = Hash.new(0)

      collect_from_data_attributes(doc, candidates)
      collect_from_links(doc, candidates)
      collect_from_scripts(doc, candidates)

      pick_best(candidates)
    rescue StandardError => e
      Rails.logger.warn("IkeaCategoryProbeService sku=#{@product.sku}: #{e.class} #{e.message}")
      nil
    end

    private

    def pl_product_url
      source = @product.url.to_s.strip
      if source.present?
        url = source
        url = url.sub(%r{https?://www\.ikea\.com/[^/]+/[^/]+/}, "https://www.ikea.com/pl/pl/")
        return url
      end

      article = extract_article(@product.sku) || extract_article(@product.item_no)
      return nil if article.blank?

      "https://www.ikea.com/pl/pl/p/-#{article}/"
    end

    def extract_article(raw)
      raw.to_s.match(/(\d{8})/)&.captures&.first
    end

    def collect_from_data_attributes(doc, candidates)
      selectors = %w[data-category-id data-categoryid data-category-id data-category data-categoryid]
      selectors.each do |attr|
        doc.css("[#{attr}]").each do |node|
          register_candidate(node[attr], candidates)
        end
      end
    end

    def collect_from_links(doc, candidates)
      doc.css('a[href*="/cat/"]').each do |link|
        href = link["href"].to_s
        next if href.blank?

        href.scan(%r{/cat/[^/"'\s]*?(\d{3,})}) { |m| register_candidate(m[0], candidates) }
      end
    end

    def collect_from_scripts(doc, candidates)
      doc.css("script").each do |script|
        text = script.text.to_s
        next if text.blank?

        text.scan(/"categoryId"\s*:\s*"?(?<id>\d{3,})"?/i) { |m| register_candidate(m[0], candidates) }
        text.scan(/"category_id"\s*:\s*"?(?<id>\d{3,})"?/i) { |m| register_candidate(m[0], candidates) }
        text.scan(%r{/cat/[^/"'\s]*?(\d{3,})}) { |m| register_candidate(m[0], candidates) }
      end
    end

    def register_candidate(raw, candidates)
      id = raw.to_s.strip
      return if id.blank?
      return unless id.match?(CATEGORY_ID_PATTERN)

      candidates[id] += 1
    end

    def pick_best(candidates)
      return nil if candidates.empty?

      existing_ids = Category.where(ikea_id: candidates.keys).pluck(:ikea_id).to_set
      preferred = candidates.select { |id, _| existing_ids.include?(id) }
      source = preferred.presence || candidates

      source.max_by { |id, score| [score, id.length, id] }&.first
    end
  end
end
