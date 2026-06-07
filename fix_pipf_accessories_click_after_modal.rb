#!/usr/bin/env ruby
# Fix PIPF accessories modal opening in PlDetailsFetcher.
#
# Context:
# - Ferrum proxy auth is already fixed.
# - Headless opens product-details modal first.
# - Accessories must be opened after closing any active modal/sheet.
#
# Usage from Rails project root:
#   ruby -c fix_pipf_accessories_click_after_modal.rb
#   ruby fix_pipf_accessories_click_after_modal.rb
#   ruby -c app/lib/pl_details_fetcher.rb

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

if src.include?("PlDetailsFetcher.try_open_accessories_modal!: closing active PIPF dialogs before accessories click")
  puts "Already patched: enhanced accessories modal clicker is present."
  exit 0
end

start_marker = "  def try_open_accessories_modal!(browser)\n"
end_marker = "  # В SSR есть кнопка открытия модалки аксессуаров"

start_idx = src.index(start_marker)
abort "Could not find start of try_open_accessories_modal!" unless start_idx

end_idx = src.index(end_marker, start_idx)
abort "Could not find end marker after try_open_accessories_modal!" unless end_idx

new_method = <<~'RUBY'
  def try_open_accessories_modal!(browser)
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: closing active PIPF dialogs before accessories click"

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

          if (candidates.length > 0) {
            candidates[0].click();
            return true;
          }

          document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
          window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true }));
          return false;
        })();
      JS
      sleep(0.6)
    rescue => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: close existing modal failed: #{e.message}"
    end

    clicked = browser.evaluate(<<~'JS')
      (function() {
        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

        const isVisible = (el) => {
          if (!el) return false;
          const rect = el.getBoundingClientRect();
          const style = window.getComputedStyle(el);
          return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
        };

        const normalize = (value) => (value || "").toString().toLowerCase();

        const markerRe = /pokaż wszystkie akcesoria|akcesoria|akcesor|accessories|accessory|аксессуар|аксес|related|upsell|pipf-upsell|pipf-accessories/i;

        const collectCandidates = () => {
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

          return Array.from(document.querySelectorAll(selectors)).filter((el) => {
            const haystack = [
              el.innerText,
              el.textContent,
              el.getAttribute("aria-label"),
              el.getAttribute("title"),
              el.getAttribute("data-testid"),
              el.className,
              el.id
            ].join(" ");

            return isVisible(el) && markerRe.test(haystack);
          });
        };

        const tryClick = () => {
          const candidates = collectCandidates();

          // Prefer explicit "show all accessories" buttons/links.
          candidates.sort((a, b) => {
            const ha = normalize([a.innerText, a.textContent, a.getAttribute("aria-label"), a.className].join(" "));
            const hb = normalize([b.innerText, b.textContent, b.getAttribute("aria-label"), b.className].join(" "));

            const score = (h) => {
              let s = 0;
              if (/pokaż wszystkie akcesoria|show all accessories|все аксесс/i.test(h)) s += 100;
              if (/akcesoria|accessories|аксесс/i.test(h)) s += 50;
              if (/upsell|pipf-upsell|pipf-accessories/i.test(h)) s += 25;
              if (/informacje o produkcie|подробная информация|product details/i.test(h)) s -= 100;
              return s;
            };

            return score(hb) - score(ha);
          });

          const target = candidates[0];
          if (!target) return false;

          target.scrollIntoView({ block: "center", inline: "center" });
          target.click();
          return true;
        };

        if (tryClick()) return true;

        // Some IKEA sections are lazy-rendered only after scrolling below details.
        const heights = [0.35, 0.55, 0.75, 0.9, 1.0];
        for (const h of heights) {
          window.scrollTo(0, Math.floor(document.body.scrollHeight * h));
          if (tryClick()) return true;
        }

        return false;
      })();
    JS

    unless clicked
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: accessories trigger not found"
      return false
    end

    20.times do |i|
      sleep(0.5)
      opened = browser.evaluate(<<~'JS')
        (function() {
          return document.querySelector(".pipf-upsell-modal") !== null ||
            document.querySelector("[class*='upsell'] [data-product-number]") !== null ||
            document.querySelector("[class*='accessories'] [data-product-number]") !== null;
        })();
      JS

      if opened
        Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: accessories opened after #{(i + 1) * 0.5}s"
        return true
      end
    end

    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: trigger clicked but accessories modal/card list did not appear"
    false
  rescue => e
    Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
    false
  end

RUBY

src = src[0...start_idx] + new_method + src[end_idx..]

backup = "#{path}.bak_accessories_click_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Check:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n \"closing active PIPF dialogs\\|accessories trigger not found\\|accessories opened\" app/lib/pl_details_fetcher.rb"
