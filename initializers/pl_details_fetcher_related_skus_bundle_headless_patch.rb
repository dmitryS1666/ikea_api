# frozen_string_literal: true

# Ensures category related-products harvesting can use PIPF accessories that are
# available only after headless interaction with the accessories block.
#
# The original related_skus_bundle_for_product_url may return [] before reaching
# headless when static HTML has no direct product links. Category harvesting uses
# this method, so we explicitly fallback to fetch_modal_with_headless_browser and
# merge its related_products plus cached SKUs collected during the click.
module PlDetailsFetcherRelatedSkusBundleHeadlessPatch
  def related_skus_bundle_for_product_url(url)
    full_url = url.to_s.start_with?("http") ? url.to_s : "https://www.ikea.com#{url}"

    skus = []
    doc = nil

    begin
      html = fetch_with_proxy(full_url)
      if html.present?
        doc = Nokogiri::HTML(html)
        skus = Array(merge_related_product_skus_from_document(doc))
      else
        Rails.logger.warn "PlDetailsFetcher.related_skus_bundle_for_product_url: empty static HTML for #{full_url}"
      end
    rescue => e
      Rails.logger.warn "PlDetailsFetcher.related_skus_bundle_for_product_url: static fetch failed for #{full_url}: #{e.class} - #{e.message}"
    end

    should_use_headless =
      self.class.headless_browser_executable_available? &&
      (skus.empty? || doc.nil? || accessories_modal_clickable?(doc))

    if should_use_headless
      begin
        head = fetch_modal_with_headless_browser(full_url)
        skus += Array(head[:related_products] || head["related_products"])
        skus += Array(instance_variable_get(:@pipf_accessories_found_skus))
      rescue => e
        Rails.logger.warn "PlDetailsFetcher.related_skus_bundle_for_product_url: headless fallback failed for #{full_url}: #{e.class} - #{e.message}"
      end
    end

    scope_article = normalize_bundle_sku_token(instance_variable_get(:@scope_sku)).to_s.sub(/\As/i, "")

    skus
      .map { |sku| normalize_bundle_sku_token(sku) }
      .compact
      .uniq
      .reject { |sku| scope_article.present? && sku.to_s.sub(/\As/i, "") == scope_article }
  end

  private

  def normalize_bundle_sku_token(value)
    token = value.is_a?(Hash) ? (value["sku"] || value[:sku] || value["item_no"] || value[:item_no]) : value
    token = token.to_s.gsub(/[^0-9a-z]/i, "")
    return nil if token.blank?

    token if token.match?(/\A\d{8}\z/i) || token.match?(/\As\d{8}\z/i)
  end
end

Rails.application.config.to_prepare do
  require_dependency Rails.root.join("app/lib/pl_details_fetcher").to_s

  unless PlDetailsFetcher.ancestors.include?(PlDetailsFetcherRelatedSkusBundleHeadlessPatch)
    PlDetailsFetcher.prepend(PlDetailsFetcherRelatedSkusBundleHeadlessPatch)
  end
end
