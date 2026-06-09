# frozen_string_literal: true

# Final PIPF accessories hotfix.
#
# Previous layer can detect the first product links after clicking
# "show all accessories", but on IKEA pages the full upsell modal may be
# populated a little later and contains many more cards in
# .pipf-upsell-modal__content-wrapper / .pipf-upsell-modal__card.
#
# This layer loads after zz_pl_details_fetcher_pipf_related_final_patch and
# overrides only the click/wait part. Existing bundle/extraction patches keep
# merging @pipf_accessories_found_skus into related_products.

module PlDetailsFetcherPipfFullModalAccessoriesPatch
  private

  def try_open_accessories_modal!(browser)
    @pipf_accessories_found_skus = []

    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: full upsell modal accessories collector"
    )

    pipf_full_modal_close_active_dialogs(browser)

    button = browser.at_css(".pipf-accessories-grid__add-accessories-button")

    unless button
      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: .pipf-accessories-grid__add-accessories-button not found"
      )
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

      sleep(0.35)
      button.click

      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: clicked .pipf-accessories-grid__add-accessories-button"
      )
    rescue => e
      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: node click failed: #{e.class} - #{e.message}"
      )

      clicked = browser.evaluate(<<~'JS')
        (function() {
          const btn = document.querySelector(".pipf-accessories-grid__add-accessories-button");
          if (!btn) return false;

          try {
            btn.scrollIntoView({ block: "center", inline: "center" });
            btn.click();
          } catch (e) {
            btn.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
          }

          return true;
        })();
      JS

      unless clicked
        Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: js click failed"
        return false
      end
    end

    timeout_seconds =
      ENV.fetch(
        "PIPF_ACCESSORIES_FULL_MODAL_TIMEOUT",
        ENV.fetch("PIPF_ACCESSORIES_TIMEOUT", "8")
      ).to_f

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
    best_skus = []
    stable_ticks = 0
    tick = 0

    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep(0.5)
      tick += 1

      html = browser.body.to_s
      modal_present = html.include?("pipf-upsell-modal") || html.include?("pipf-upsell-modal__card")
      current_skus = pipf_full_modal_accessory_skus_from_html(html)

      if current_skus.length > best_skus.length
        best_skus = current_skus
        stable_ticks = 0

        Rails.logger.debug(
          "PlDetailsFetcher.try_open_accessories_modal!: full modal skus growing " \
          "after #{tick * 0.5}s modal=#{modal_present} count=#{best_skus.length} skus=#{best_skus.inspect}"
        )
      elsif current_skus == best_skus && best_skus.any?
        stable_ticks += 1
      end

      break if modal_present && best_skus.any? && stable_ticks >= 3
    end

    if best_skus.any?
      @pipf_accessories_found_skus = best_skus

      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: full modal accessories collected " \
        "count=#{best_skus.length} skus=#{best_skus.inspect}"
      )

      return true
    end

    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: accessories button clicked but full modal product SKUs did not appear"
    )

    false
  rescue => e
    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
    )
    false
  end

  def pipf_full_modal_accessory_skus_from_html(html)
    return [] if html.blank?

    doc = Nokogiri::HTML(html.to_s)

    attr_skus =
      doc.css(
        ".pipf-upsell-modal [data-product-number], " \
        ".pipf-upsell-modal__content-wrapper [data-product-number], " \
        ".pipf-upsell-modal__content [data-product-number], " \
        ".pipf-upsell-modal__card [data-product-number], " \
        "[class*='upsell-modal'] [data-product-number]"
      ).filter_map do |el|
        pipf_full_modal_normalize_sku(el["data-product-number"])
      end

    link_skus =
      doc.css(
        ".pipf-upsell-modal a[href*='/p/'], " \
        ".pipf-upsell-modal__content-wrapper a[href*='/p/'], " \
        ".pipf-upsell-modal__content a[href*='/p/'], " \
        ".pipf-upsell-modal__card a[href*='/p/'], " \
        "[class*='upsell-modal'] a[href*='/p/']"
      ).filter_map do |a|
        pipf_full_modal_sku_from_href(a["href"].to_s)
      end

    pipf_full_modal_filter_skus(attr_skus + link_skus)
  end

  def pipf_full_modal_sku_from_href(href)
    token =
      href[/\-([a-z]?\d{8})\/?(?:[#?].*)?$/i, 1] ||
      href[%r{/p/[^/]*-([a-z]?\d{8})/?(?:[#?].*)?$}i, 1]

    pipf_full_modal_normalize_sku(token)
  end

  def pipf_full_modal_normalize_sku(token)
    return nil if token.blank?

    if respond_to?(:normalize_product_token, true)
      normalized = send(:normalize_product_token, token)
      return normalized.to_s.strip.presence
    end

    token.to_s.strip.presence
  end

  def pipf_full_modal_filter_skus(skus)
    scope_article =
      pipf_full_modal_normalize_sku(instance_variable_get(:@scope_sku)).to_s.sub(/\As/i, "")

    skus
      .filter_map { |sku| pipf_full_modal_normalize_sku(sku) }
      .uniq
      .reject { |sku| sku.to_s.sub(/\As/i, "") == scope_article }
  end

  def pipf_full_modal_close_active_dialogs(browser)
    browser.evaluate(<<~'JS')
      (function() {
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
        return true;
      })();
    JS

    sleep(0.8)
  rescue => e
    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: escape close failed: #{e.class} - #{e.message}"
    )
  end
end

Rails.application.config.to_prepare do
  require_dependency Rails.root.join("app/lib/pl_details_fetcher").to_s

  unless PlDetailsFetcher.ancestors.include?(PlDetailsFetcherPipfFullModalAccessoriesPatch)
    PlDetailsFetcher.prepend(PlDetailsFetcherPipfFullModalAccessoriesPatch)
  end
end
