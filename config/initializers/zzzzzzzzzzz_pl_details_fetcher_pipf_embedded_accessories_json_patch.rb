# frozen_string_literal: true

# IKEA stores full accessories data as embedded JSON near .pipf-accessories-grid.
# In headless Chrome the "show all accessories" button can be visible/clickable
# but not open the modal. So collect SKUs directly from embedded accessories JSON.

module PlDetailsFetcherPipfEmbeddedAccessoriesJsonPatch
  private

  def try_open_accessories_modal!(browser)
    skus = pipf_embedded_accessories_json_skus(browser)

    if skus.any?
      @pipf_accessories_found_skus = skus

      Rails.logger.debug(
        "PlDetailsFetcher.try_open_accessories_modal!: embedded accessories JSON collected " \
        "count=#{skus.length} skus=#{skus.inspect}"
      )

      return true
    end

    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: embedded accessories JSON empty, fallback to previous collector"
    )

    super(browser)
  rescue => e
    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: embedded accessories JSON failed #{e.class} - #{e.message}"
    )

    super(browser)
  end

  def pipf_embedded_accessories_json_skus(browser)
    texts = browser.evaluate(<<~'JS')
      (function() {
        var out = [];

        function pushText(el) {
          if (!el) return;

          var text = [
            el.textContent,
            el.innerText,
            el.getAttribute && el.getAttribute("data-props"),
            el.getAttribute && el.getAttribute("data-state"),
            el.getAttribute && el.getAttribute("data-json")
          ].join("\\n");

          if (text.indexOf('"accessories"') >= 0 && text.indexOf('"upsells"') >= 0) {
            out.push(text);
          }
        }

        Array.prototype.slice.call(document.querySelectorAll(
          ".pipf-accessories-grid, [class*='accessories-grid'], [class*='accessories']"
        )).forEach(function(el) {
          pushText(el);
          pushText(el.parentElement);
          pushText(el.parentElement && el.parentElement.parentElement);
        });

        Array.prototype.slice.call(document.querySelectorAll("script")).forEach(function(script) {
          pushText(script);
        });

        if (out.length === 0 && document.body) {
          pushText(document.body);
        }

        return out.slice(0, 20);
      })();
    JS

    skus = []

    Array(texts).each do |text|
      skus.concat(pipf_embedded_accessories_extract_skus_from_text(text.to_s))
    end

    pipf_embedded_accessories_filter_skus(skus)
  rescue => e
    Rails.logger.debug(
      "PlDetailsFetcher.pipf_embedded_accessories_json_skus: #{e.class} - #{e.message}"
    )
    []
  end

  def pipf_embedded_accessories_extract_skus_from_text(text)
    return [] if text.blank?
    return [] unless text.include?('"accessories"') && text.include?('"upsells"')

    candidates = []

    start_index = 0

    while (idx = text.index('{"accessories"', start_index))
      json = pipf_embedded_accessories_balanced_json_object(text, idx)

      if json.present?
        candidates.concat(pipf_embedded_accessories_skus_from_json_string(json))
        start_index = idx + json.length
      else
        start_index = idx + 1
      end
    end

    unescaped = CGI.unescapeHTML(text.to_s)

    if unescaped != text
      start_index = 0

      while (idx = unescaped.index('{"accessories"', start_index))
        json = pipf_embedded_accessories_balanced_json_object(unescaped, idx)

        if json.present?
          candidates.concat(pipf_embedded_accessories_skus_from_json_string(json))
          start_index = idx + json.length
        else
          start_index = idx + 1
        end
      end
    end

    candidates.concat(
      text.scan(/"(?:(?:itemNo)|(?:itemNumber)|(?:productNumber)|(?:productNo)|(?:articleNumber)|(?:id)|(?:sku))"\s*:\s*"?(s?\d{8})"?/i).flatten
    )

    candidates
  end

  def pipf_embedded_accessories_balanced_json_object(text, start_idx)
    depth = 0
    in_string = false
    escape = false

    i = start_idx

    while i < text.length
      ch = text[i]

      if escape
        escape = false
      elsif ch == "\\"
        escape = true
      elsif ch == '"'
        in_string = !in_string
      elsif !in_string
        if ch == "{"
          depth += 1
        elsif ch == "}"
          depth -= 1

          return text[start_idx..i] if depth.zero?
        end
      end

      i += 1
    end

    nil
  end

  def pipf_embedded_accessories_skus_from_json_string(json)
    parsed = JSON.parse(json)
    values = []

    pipf_embedded_accessories_walk_json(parsed, values)

    values
  rescue JSON::ParserError
    []
  end

  def pipf_embedded_accessories_walk_json(value, out)
    case value
    when Hash
      value.each do |key, child|
        key_s = key.to_s.downcase

        if key_s.match?(/sku|item|article|product|id|number|part/)
          out << child if child.is_a?(String) || child.is_a?(Numeric)
        end

        pipf_embedded_accessories_walk_json(child, out)
      end
    when Array
      value.each { |child| pipf_embedded_accessories_walk_json(child, out) }
    when String
      out.concat(value.scan(/(?:^|[-_\/])((?:s)?\d{8})(?:$|[^\d])/i).flatten)
    end
  end

  def pipf_embedded_accessories_filter_skus(values)
    scope_article =
      if respond_to?(:normalize_product_token, true)
        send(:normalize_product_token, instance_variable_get(:@scope_sku)).to_s.sub(/\As/i, "")
      else
        instance_variable_get(:@scope_sku).to_s.gsub(/[^0-9a-z]/i, "").sub(/\As/i, "")
      end

    Array(values)
      .filter_map { |value| pipf_embedded_accessories_normalize_sku(value) }
      .uniq
      .reject { |sku| scope_article.present? && sku.to_s.sub(/\As/i, "") == scope_article }
  end

  def pipf_embedded_accessories_normalize_sku(value)
    return nil if value.blank?

    token = value.to_s.gsub(/[^0-9a-z]/i, "").downcase
    token = token[/s?\d{8}/i].to_s.downcase if token.length > 9

    return token if token.match?(/\A\d{8}\z/)
    return token if token.match?(/\As\d{8}\z/)

    nil
  end
end

Rails.application.config.to_prepare do
  require "json"
  require "cgi"
  require_dependency Rails.root.join("app/lib/pl_details_fetcher").to_s

  unless PlDetailsFetcher.ancestors.include?(PlDetailsFetcherPipfEmbeddedAccessoriesJsonPatch)
    PlDetailsFetcher.prepend(PlDetailsFetcherPipfEmbeddedAccessoriesJsonPatch)
  end
end
