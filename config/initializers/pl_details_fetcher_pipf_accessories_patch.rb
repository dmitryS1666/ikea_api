# frozen_string_literal: true

# Hotfix for IKEA PIPF accessories.
#
# Why this exists:
# - PIPF pages render accessories as a visible grid first.
# - The real products appear after clicking `.pipf-accessories-grid__add-accessories-button`.
# - After that click IKEA may render products only as `a[href*='/p/']`, without `data-product-number`.
#
# This patch is intentionally isolated in an initializer so it can be applied safely on top of
# already patched branches without fighting the current shape of app/lib/pl_details_fetcher.rb.

module PlDetailsFetcherPipfAccessoriesPatch
  ACCESSORIES_BUTTON_SELECTOR = ".pipf-accessories-grid__add-accessories-button"
  ACCESSORIES_LINK_SELECTOR = [
    ".pipf-upsell-modal a[href*='/p/']",
    ".pipf-accessories-grid a[href*='/p/']",
    "[class*='accessories'] a[href*='/p/']",
    "[class*='upsell'] a[href*='/p/']"
  ].join(", ")

  def try_open_accessories_modal!(browser)
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: direct accessories button clicker with parent SKU guard"

    close_open_pipf_dialogs_for_accessories!(browser)

    button = browser.at_css(ACCESSORIES_BUTTON_SELECTOR)
    unless button
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{ACCESSORIES_BUTTON_SELECTOR} not found"
      return false
    end

    begin
      browser.evaluate(<<~JS)
        (function() {
          const btn = document.querySelector(#{ACCESSORIES_BUTTON_SELECTOR.to_json});
          if (!btn) return false;
          btn.scrollIntoView({ block: "center", inline: "center" });
          return true;
        })();
      JS
      sleep(0.4)
    rescue StandardError => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: scroll failed: #{e.class} - #{e.message}"
    end

    begin
      button.click
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: clicked #{ACCESSORIES_BUTTON_SELECTOR}"
    rescue StandardError => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: node click failed: #{e.class} - #{e.message}"

      clicked = browser.evaluate(<<~JS)
        (function() {
          const btn = document.querySelector(#{ACCESSORIES_BUTTON_SELECTOR.to_json});
          if (!btn) return false;
          try {
            btn.click();
          } catch (e) {
            btn.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
          }
          return true;
        })();
      JS

      return false unless clicked
    end

    10.times do |i|
      sleep(0.5)

      doc = Nokogiri::HTML(browser.body.to_s)

      attr_skus = extract_pipf_accessory_attribute_skus(doc)
      link_skus = extract_pipf_accessory_link_skus(doc)

      accessory_attr_skus = reject_pipf_parent_skus(attr_skus)
      accessory_link_skus = reject_pipf_parent_skus(link_skus)

      if accessory_attr_skus.any? || accessory_link_skus.any?
        @pipf_accessories_found_skus = (accessory_attr_skus + accessory_link_skus).uniq

        Rails.logger.debug(
          "PlDetailsFetcher.try_open_accessories_modal!: accessories opened after #{(i + 1) * 0.5}s " \
          "attr_skus=#{accessory_attr_skus.inspect} link_skus=#{accessory_link_skus.inspect}"
        )
        return true
      end
    end

    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: accessories button clicked but no product links appeared"
    false
  rescue StandardError => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
    false
  end

  def extract_related_products_from_accessories_modal(doc)
    related = begin
      Array(super)
    rescue NoMethodError
      []
    end

    related.concat(extract_pipf_accessory_grid_skus(doc))
    related.concat(Array(@pipf_accessories_found_skus))
    reject_pipf_parent_skus(related).uniq
  end

  def extract_related_products_from_accessories_grid(doc)
    reject_pipf_parent_skus(extract_pipf_accessory_grid_skus(doc) + Array(@pipf_accessories_found_skus)).uniq
  end

  def merge_related_product_skus_from_document(doc)
    related = begin
      Array(super)
    rescue NoMethodError
      []
    end

    related.concat(extract_pipf_accessory_grid_skus(doc))
    related.concat(Array(@pipf_accessories_found_skus))
    reject_pipf_parent_skus(related).uniq
  end

  private

  def close_open_pipf_dialogs_for_accessories!(browser)
    browser.evaluate(<<~'JS')
      (function() {
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        return true;
      })();
    JS
    sleep(0.8)
  rescue StandardError => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: escape close failed: #{e.class} - #{e.message}"
  end

  def extract_pipf_accessory_attribute_skus(doc)
    return [] unless doc

    doc.css(
      ".pipf-accessories-grid [data-product-number], .pipf-accessories-grid [data-ref-id], .pipf-accessories-grid [data-item-no], .pipf-accessories-grid [data-product-id], " \
      "[class*='accessories'] [data-product-number], [class*='accessories'] [data-ref-id], [class*='accessories'] [data-item-no], [class*='accessories'] [data-product-id], " \
      "[class*='upsell'] [data-product-number], [class*='upsell'] [data-ref-id], [class*='upsell'] [data-item-no], [class*='upsell'] [data-product-id], " \
      ".pipf-upsell-modal [data-product-number], .pipf-upsell-modal [data-ref-id], .pipf-upsell-modal [data-item-no], .pipf-upsell-modal [data-product-id]"
    ).flat_map do |el|
      %w[data-product-number data-ref-id data-item-no data-product-id].filter_map do |attr|
        normalize_pipf_accessory_token(el[attr])
      end
    end.uniq
  end

  def extract_pipf_accessory_grid_skus(doc)
    return [] unless doc

    skus = extract_pipf_accessory_attribute_skus(doc)
    skus.concat(extract_pipf_accessory_link_skus(doc))

    reject_pipf_parent_skus(skus).uniq
  end

  def extract_pipf_accessory_link_skus(doc)
    return [] unless doc

    doc.css(ACCESSORIES_LINK_SELECTOR).filter_map do |a|
      href = a["href"].to_s
      token =
        href[/\-([a-z]?\d{8})\/?(?:[#?].*)?$/i, 1] ||
        href[%r{/p/[^/]*-([a-z]?\d{8})/?(?:[#?].*)?$}i, 1]

      normalize_pipf_accessory_token(token)
    end.uniq
  end

  def reject_pipf_parent_skus(skus)
    scope_article = normalize_pipf_accessory_token(instance_variable_get(:@scope_sku)).to_s.sub(/\As/i, "")
    return Array(skus).compact if scope_article.blank?

    Array(skus).compact.reject do |sku|
      sku.to_s.sub(/\As/i, "") == scope_article
    end
  end

  def normalize_pipf_accessory_token(value)
    if respond_to?(:normalize_product_token, true)
      normalize_product_token(value)
    else
      token = value.to_s.gsub(/[^0-9a-z]/i, "")
      token.presence
    end
  end
end

Rails.application.config.to_prepare do
  require Rails.root.join("app/lib/pl_details_fetcher").to_s unless defined?(PlDetailsFetcher)

  unless PlDetailsFetcher.ancestors.include?(PlDetailsFetcherPipfAccessoriesPatch)
    PlDetailsFetcher.prepend(PlDetailsFetcherPipfAccessoriesPatch)
  end
end
