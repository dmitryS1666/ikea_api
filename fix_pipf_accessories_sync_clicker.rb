#!/usr/bin/env ruby
# Replace try_open_accessories_modal! with a synchronous implementation.
# It avoids async JS returning `{}` in Ferrum and logs clicked/tried candidates.
#
# Usage from Rails project root:
#   ruby -c fix_pipf_accessories_sync_clicker.rb
#   ruby fix_pipf_accessories_sync_clicker.rb
#   ruby -c app/lib/pl_details_fetcher.rb

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

if src.include?("sync accessories candidates clicker")
  puts "Already patched: sync accessories clicker is present."
  exit 0
end

start_idx = src.index("  def try_open_accessories_modal!(browser)\n")
abort "try_open_accessories_modal! not found" unless start_idx

end_markers = [
  "  # В SSR есть кнопка открытия модалки аксессуаров",
  "  def accessories_modal_clickable?(doc)\n",
  "  def included_products_sheet_clickable?(doc)\n"
]

end_idx = end_markers.filter_map { |marker| src.index(marker, start_idx) }.min
abort "Could not find end of try_open_accessories_modal! method" unless end_idx

new_method = <<~'RUBY'
  def try_open_accessories_modal!(browser)
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: sync accessories candidates clicker"

    begin
      browser.evaluate(<<~'JS')
        (function() {
          const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          };

          const closeRe = /закры|close|zamknij|fechar|cerrar|chiudi|sluiten/i;
          const candidates = Array.from(document.querySelectorAll("button, [role='button'], a")).filter((el) => {
            const haystack = [
              el.innerText,
              el.textContent,
              el.getAttribute("aria-label"),
              el.getAttribute("title"),
              el.getAttribute("data-testid"),
              el.className,
              el.id
            ].join(" ");

            return isVisible(el) && closeRe.test(haystack);
          });

          if (candidates[0]) {
            candidates[0].click();
            return true;
          }

          document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
          window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
          return false;
        })();
      JS
      sleep(0.8)
    rescue => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: close existing modal failed: #{e.class} - #{e.message}"
    end

    tried = []

    [0.0, 0.25, 0.45, 0.65, 0.85, 1.0].each do |scroll_point|
      browser.evaluate("window.scrollTo(0, Math.floor(document.body.scrollHeight * #{scroll_point}));")
      sleep(0.6)

      candidates = browser.evaluate(<<~'JS')
        (function() {
          const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          };

          const textOf = (el) => [
            el.innerText,
            el.textContent,
            el.getAttribute("aria-label"),
            el.getAttribute("title"),
            el.getAttribute("data-testid"),
            el.className,
            el.id
          ].join(" ").replace(/\\s+/g, " ").trim();

          const markerRe = /pokaż wszystkie akcesoria|akcesoria|akcesor|accessories|accessory|аксессуар|аксес|upsell|pipf-upsell|pipf-accessories/i;
          const badRe = /informacje o produkcie|подробная информация|product details|measurements|wymiary|размер/i;

          const selectors = [
            "button",
            "a",
            "[role='button']",
            "[class*='accessories']",
            "[class*='upsell']",
            "[data-testid*='accessories']",
            "[data-testid*='upsell']",
            "[aria-label*='akces']",
            "[aria-label*='access']",
            "[aria-label*='аксес']"
          ].join(",");

          return Array.from(document.querySelectorAll(selectors)).map((el, index) => {
            const label = textOf(el);
            return {
              index: index,
              label: label.slice(0, 180),
              tag: el.tagName,
              role: el.getAttribute("role"),
              visible: isVisible(el),
              matched: markerRe.test(label) && !badRe.test(label)
            };
          }).filter((item) => item.visible && item.matched).sort((a, b) => {
            const score = (item) => {
              const h = item.label;
              let s = 0;
              if (/pokaż wszystkie akcesoria|show all accessories|все аксесс/i.test(h)) s += 100;
              if (/akcesoria|accessories|аксесс/i.test(h)) s += 50;
              if (/upsell|pipf-upsell|pipf-accessories/i.test(h)) s += 25;
              if (item.tag === "BUTTON") s += 10;
              if (item.role === "button") s += 8;
              return s;
            };

            return score(b) - score(a);
          }).slice(0, 15);
        })();
      JS

      Array(candidates).each_with_index do |candidate, candidate_position|
        label = candidate["label"].to_s
        tried << label

        clicked = browser.evaluate(<<~JS)
          (function() {
            const isVisible = (el) => {
              if (!el) return false;
              const rect = el.getBoundingClientRect();
              const style = window.getComputedStyle(el);
              return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
            };

            const textOf = (el) => [
              el.innerText,
              el.textContent,
              el.getAttribute("aria-label"),
              el.getAttribute("title"),
              el.getAttribute("data-testid"),
              el.className,
              el.id
            ].join(" ").replace(/\\s+/g, " ").trim();

            const markerRe = /pokaż wszystkie akcesoria|akcesoria|akcesor|accessories|accessory|аксессуар|аксес|upsell|pipf-upsell|pipf-accessories/i;
            const badRe = /informacje o produkcie|подробная информация|product details|measurements|wymiary|размер/i;

            const selectors = [
              "button",
              "a",
              "[role='button']",
              "[class*='accessories']",
              "[class*='upsell']",
              "[data-testid*='accessories']",
              "[data-testid*='upsell']",
              "[aria-label*='akces']",
              "[aria-label*='access']",
              "[aria-label*='аксес']"
            ].join(",");

            const items = Array.from(document.querySelectorAll(selectors)).filter((el) => {
              const label = textOf(el);
              return isVisible(el) && markerRe.test(label) && !badRe.test(label);
            }).sort((a, b) => {
              const score = (el) => {
                const h = textOf(el);
                let s = 0;
                if (/pokaż wszystkie akcesoria|show all accessories|все аксесс/i.test(h)) s += 100;
                if (/akcesoria|accessories|аксесс/i.test(h)) s += 50;
                if (/upsell|pipf-upsell|pipf-accessories/i.test(h)) s += 25;
                if (el.tagName === "BUTTON") s += 10;
                if (el.getAttribute("role") === "button") s += 8;
                return s;
              };
              return score(b) - score(a);
            });

            const target = items[#{candidate_position}];
            if (!target) return false;

            const inner = target.matches("button,a,[role='button']") ? target : target.querySelector("button,a,[role='button']");
            const clickTarget = inner || target;

            clickTarget.scrollIntoView({ block: "center", inline: "center" });

            try {
              clickTarget.click();
            } catch (e) {
              clickTarget.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
            }

            return true;
          })();
        JS

        next unless clicked

        14.times do
          sleep(0.35)

          opened = browser.evaluate(<<~'JS')
            (function() {
              return document.querySelector(".pipf-upsell-modal") !== null ||
                document.querySelectorAll(".pipf-upsell-modal [data-product-number]").length > 0 ||
                document.querySelectorAll("[class*='upsell'] [data-product-number], [class*='accessories'] [data-product-number]").length > 0;
            })();
          JS

          if opened
            skus = browser.evaluate(<<~'JS')
              (function() {
                return Array.from(document.querySelectorAll("[data-product-number]"))
                  .map((el) => el.getAttribute("data-product-number"))
                  .filter(Boolean);
              })();
            JS

            Rails.logger.debug(
              "PlDetailsFetcher.try_open_accessories_modal!: opened=true clicked=#{label.inspect} skus=#{Array(skus).inspect}"
            )
            return true
          end
        end
      end
    end

    Rails.logger.debug(
      "PlDetailsFetcher.try_open_accessories_modal!: opened=false tried=#{tried.first(30).inspect}"
    )
    false
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
    false
  end

RUBY

src = src[0...start_idx] + new_method + src[end_idx..]

backup = "#{path}.bak_sync_accessories_clicker_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Check:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n 'sync accessories candidates clicker\\|opened=false tried\\|opened=true clicked' app/lib/pl_details_fetcher.rb"
