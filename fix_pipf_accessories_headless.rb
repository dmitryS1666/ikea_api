path = 'app/lib/pl_details_fetcher.rb'
source = File.read(path)
backup = "#{path}.bak_pipf_accessories_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, source)

source = source.sub(
  "      accessories_opened = try_open_accessories_modal!(browser)\n\n      measurements_opened = try_open_measurements_sheet!(browser)",
  <<~'CODE'.rstrip
      # Аксессуары нужно открывать/читать отдельно от остальных sheet/modal.
      # Иначе последующий клик по measurements может заменить текущий DOM,
      # и .pipf-upsell-modal исчезнет до извлечения related_products.
      close_pipf_overlays!(browser)
      accessories_related = []
      if try_open_accessories_modal!(browser)
        accessories_doc = Nokogiri::HTML(browser.body)
        accessories_related = (
          extract_related_products_from_accessories_modal(accessories_doc) +
          extract_related_products_from_accessories_grid(accessories_doc)
        ).map(&:to_s).uniq
      end
      close_pipf_overlays!(browser)

      measurements_opened = try_open_measurements_sheet!(browser)
  CODE
)

source = source.sub(
  "      accessories_related = extract_related_products_from_accessories_modal(modal_doc)\n      recommendation_related = extract_related_products_from_recommendation_panel(modal_doc)\n      related = (Array(accessories_related) + Array(recommendation_related)).map(&:to_s).uniq",
  <<~'CODE'.rstrip
      # На некоторых PIPF-страницах аксессуарная модалка уже закрыта/заменена
      # к моменту финального browser.body, поэтому не теряем список, снятый
      # сразу после открытия аксессуаров.
      final_accessories_related = extract_related_products_from_accessories_modal(modal_doc)
      recommendation_related = extract_related_products_from_recommendation_panel(modal_doc)
      related = (Array(accessories_related) + Array(final_accessories_related) + Array(recommendation_related)).map(&:to_s).uniq
  CODE
)

close_method = <<~'RUBY_CODE'
  def close_pipf_overlays!(browser)
    browser.evaluate(<<~'JS')
      (function() {
        const clickIfPresent = (selector) => {
          const el = document.querySelector(selector);
          if (!el) return false;
          try { el.click(); return true; } catch (e) { return false; }
        };

        const selectors = [
          '.pipf-modal-header__close',
          '.pipf-sheets__close',
          '.pipf-modal__close',
          '[aria-label="Close"]',
          '[aria-label="Закрыть"]',
          '[aria-label="Zamknij"]',
          'button[aria-label*="close" i]',
          'button[aria-label*="закры" i]',
          'button[aria-label*="zamkn" i]'
        ];

        selectors.some(clickIfPresent);
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
        return true;
      })();
    JS
    sleep(0.3)
    true
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.close_pipf_overlays!: #{e.message}"
    false
  end

RUBY_CODE

unless source.include?('def close_pipf_overlays!')
  source = source.sub(/\n  def try_open_accessories_modal!\(browser\)/, "\n#{close_method}  def try_open_accessories_modal!(browser)")
end

try_method = <<~'RUBY_CODE'
  def try_open_accessories_modal!(browser)
    clicked = browser.evaluate(<<~'JS')
      (function() {
        const selectors = [
          "button",
          "a",
          "[role='button']",
          "[class*='accessories']",
          "[class*='upsell']",
          "[data-testid*='accessories']",
          "[data-testid*='upsell']"
        ].join(",");

        const nodes = Array.from(document.querySelectorAll(selectors));
        const matches = (el) => {
          const text = (el.innerText || el.textContent || "").trim().toLowerCase();
          const attrs = [
            el.getAttribute("aria-label"),
            el.getAttribute("data-testid"),
            el.getAttribute("data-product-name"),
            el.getAttribute("data-category"),
            el.id,
            typeof el.className === "string" ? el.className : ""
          ].join(" ").toLowerCase();
          const haystack = `${text} ${attrs}`;

          return haystack.includes("pokaż wszystkie akcesoria") ||
            haystack.includes("akcesoria") ||
            haystack.includes("akcesor") ||
            haystack.includes("accessories") ||
            haystack.includes("accessory") ||
            haystack.includes("аксессуар") ||
            haystack.includes("аксес") ||
            haystack.includes("related") ||
            haystack.includes("upsell") ||
            haystack.includes("pipf-upsell") ||
            haystack.includes("pipf-accessories");
        };

        let target = nodes.find(matches);
        if (!target) {
          window.scrollTo(0, Math.floor(document.body.scrollHeight * 0.65));
          target = Array.from(document.querySelectorAll(selectors)).find(matches);
        }

        if (!target) return false;
        target.scrollIntoView({ block: "center", inline: "center" });
        target.click();
        return true;
      })();
    JS
    return false unless clicked

    20.times do
      sleep(0.5)
      opened = browser.evaluate(<<~'JS')
        (function() {
          return document.querySelector('.pipf-upsell-modal') !== null ||
            document.querySelector('[class*="upsell"] [data-product-number]') !== null ||
            document.querySelector('[class*="accessories"] [data-product-number]') !== null;
        })();
      JS
      return true if opened
    end
    false
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.message}"
    false
  end
RUBY_CODE

source = source.sub(/  def try_open_accessories_modal!\(browser\).*?\n  # В SSR есть кнопка открытия модалки аксессуаров — без headless блок в DOM пустой\./m,
                    "#{try_method}\n\n  # В SSR есть кнопка открытия модалки аксессуаров — без headless блок в DOM пустой.")

clickable_method = <<~'RUBY_CODE'
  def accessories_modal_clickable?(doc)
    return false unless doc

    doc.css("button, a, [role='button'], [class*='accessories'], [class*='upsell'], [data-testid*='accessories'], [data-testid*='upsell']").any? do |node|
      txt = node.text.to_s.downcase
      attrs = [
        node["aria-label"],
        node["data-testid"],
        node["data-product-name"],
        node["data-category"],
        node["id"],
        node["class"]
      ].join(" ").downcase

      haystack = "#{txt} #{attrs}"
      haystack.include?("pokaż wszystkie akcesoria") ||
        haystack.include?("akcesoria") ||
        haystack.include?("akcesor") ||
        haystack.include?("accessories") ||
        haystack.include?("accessory") ||
        haystack.include?("аксессуар") ||
        haystack.include?("аксес") ||
        haystack.include?("related") ||
        haystack.include?("upsell") ||
        haystack.include?("pipf-upsell") ||
        haystack.include?("pipf-accessories")
    end
  end
RUBY_CODE

source = source.sub(/  def accessories_modal_clickable\?\(doc\).*?\n  # На PIPF кнопка строки списка/m,
                    "#{clickable_method}\n\n  # На PIPF кнопка строки списка")

File.write(path, source)
puts "patched #{path}"
puts "backup #{backup}"
