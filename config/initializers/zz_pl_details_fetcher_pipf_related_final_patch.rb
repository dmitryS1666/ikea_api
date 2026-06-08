# frozen_string_literal: true

# Final PIPF accessories patch for IKEA product pages.
#
# Why this exists:
# - PIPF accessories may be rendered only after clicking
#   .pipf-accessories-grid__add-accessories-button.
# - Some pages render accessory products as links, not data-product-number attrs.
# - Some pages render only accessory categories; in that case we must not treat the
#   current product SKU as an accessory.
# - Category related_products harvest uses PlDetailsFetcher.related_skus_bundle_for_product_url,
#   so headless-found accessories must be visible to that path as well.

module PlDetailsFetcherPipfRelatedFinalPatch
  # Keep this method public: PlDetailsFetcher.self.related_skus_bundle_for_product_url
  # calls it on a new instance with an explicit receiver.
  def related_skus_bundle_for_product_url(url)
    base = Array(super)
    normalized_base = pipf_filter_accessory_skus(base)
    return normalized_base if normalized_base.any?

    return [] unless self.class.headless_browser_executable_available?

    full_url = url.to_s.start_with?("http") ? url.to_s : "https://www.ikea.com#{url}"
    head = fetch_modal_with_headless_browser(full_url)

    pipf_filter_accessory_skus(
      Array(head[:related_products]) + Array(@pipf_accessories_found_skus)
    )
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.related_skus_bundle_for_product_url final patch: #{e.class} - #{e.message}"
    pipf_filter_accessory_skus(base)
  end

  private

  def try_open_accessories_modal!(browser)
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: final direct accessories button clicker"
    @pipf_accessories_found_skus = []

    close_active_dialogs_for_pipf_accessories(browser)

    button = browser.at_css(".pipf-accessories-grid__add-accessories-button")
    unless button
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: .pipf-accessories-grid__add-accessories-button not found"
      return false
    end

    begin
      browser.evaluate(<<~'JS')
        (function() {
          const btn = document.querySelector(".pipf-accessories-grid__add-accessories-button");
          if (!btn) return false;
          btn.scrollIntoView({ block: "center", inline: "center" });
          return true;
        })();
      JS
      sleep(0.4)
      button.click
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: clicked .pipf-accessories-grid__add-accessories-button"
    rescue => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: node click failed: #{e.class} - #{e.message}"

      begin
        browser.evaluate(<<~'JS')
          (function() {
            const btn = document.querySelector(".pipf-accessories-grid__add-accessories-button");
            if (!btn) return false;
            try {
              btn.click();
            } catch (e) {
              btn.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
            }
            return true;
          })();
        JS
      rescue => e2
        Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: js click failed: #{e2.class} - #{e2.message}"
        return false
      end
    end

    10.times do |i|
      sleep(0.5)

      found = pipf_accessory_skus_from_headless_html(browser.body.to_s)
      next if found.empty?

      @pipf_accessories_found_skus = found
      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: accessories opened after #{(i + 1) * 0.5}s " \
        "skus=#{found.inspect}"
      )
      return true
    end

    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: accessories button clicked but no product links appeared"
    false
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
    false
  end

  def merge_related_product_skus_from_document(doc)
    pipf_filter_accessory_skus(Array(super) + Array(@pipf_accessories_found_skus))
  end

  def extract_related_products_from_accessories_modal(doc)
    pipf_filter_accessory_skus(Array(super) + Array(@pipf_accessories_found_skus))
  end

  def extract_related_products_from_accessories_grid(doc)
    from_doc = doc ? pipf_accessory_skus_from_html(doc.to_html) : []
    pipf_filter_accessory_skus(Array(super) + from_doc + Array(@pipf_accessories_found_skus))
  end

  def close_active_dialogs_for_pipf_accessories(browser)
    browser.evaluate(<<~'JS')
      (function() {
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        return true;
      })();
    JS
    sleep(0.8)
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: escape close failed: #{e.class} - #{e.message}"
  end

  # Headless-specific extraction after clicking "show all accessories".
  #
  # IKEA may render product links outside .pipf-accessories-grid after the click,
  # so this method intentionally scans all /p/ links in the live browser body.
  # Static HTML parsing must keep using pipf_accessory_skus_from_html, which is
  # scoped to accessories/upsell containers to avoid unrelated product links.
  def pipf_accessory_skus_from_headless_html(html)
    return [] if html.blank?

    doc = Nokogiri::HTML(html.to_s)

    link_skus =
      doc.css("a[href*='/p/']").filter_map do |a|
        href = a["href"].to_s
        token =
          href[/\-([a-z]?\d{8})\/?(?:[#?].*)?$/i, 1] ||
          href[%r{/p/[^/]*-([a-z]?\d{8})/?(?:[#?].*)?$}i, 1]
        normalize_product_token(token)
      end

    pipf_filter_accessory_skus(pipf_accessory_skus_from_html(html) + link_skus)
  end

  def pipf_accessory_skus_from_html(html)
    return [] if html.blank?

    doc = Nokogiri::HTML(html.to_s)

    attr_skus =
      doc.css("[data-product-number], [data-ref-id], [data-item-no], [data-product-id]").filter_map do |el|
        normalize_product_token(
          el["data-product-number"] ||
          el["data-ref-id"] ||
          el["data-item-no"] ||
          el["data-product-id"]
        )
      end

    link_skus =
      doc.css(".pipf-accessories-grid a[href*='/p/'], [class*='accessories'] a[href*='/p/'], [class*='upsell'] a[href*='/p/'], .pipf-upsell-modal a[href*='/p/']").filter_map do |a|
        href = a["href"].to_s
        token =
          href[/\-([a-z]?\d{8})\/?(?:[#?].*)?$/i, 1] ||
          href[%r{/p/[^/]*-([a-z]?\d{8})/?(?:[#?].*)?$}i, 1]
        normalize_product_token(token)
      end

    pipf_filter_accessory_skus(attr_skus + link_skus)
  end

  def pipf_filter_accessory_skus(skus)
    scope_article = normalize_product_token(instance_variable_get(:@scope_sku)).to_s.sub(/\As/i, "")

    Array(skus)
      .filter_map { |sku| normalize_product_token(sku) }
      .uniq
      .reject { |sku| scope_article.present? && sku.to_s.sub(/\As/i, "") == scope_article }
  end
end

Rails.application.config.to_prepare do
  require "nokogiri"
  require_dependency Rails.root.join("app/lib/pl_details_fetcher").to_s

  unless PlDetailsFetcher.ancestors.include?(PlDetailsFetcherPipfRelatedFinalPatch)
    PlDetailsFetcher.prepend(PlDetailsFetcherPipfRelatedFinalPatch)
  end
end
