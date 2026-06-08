#!/usr/bin/env ruby
# Robust fallback fixer for PlDetailsFetcher accessories opening.
#
# Works even if `try_open_accessories_modal!` is missing in the local file:
# - replaces existing method if found;
# - otherwise inserts the method before accessories_modal_clickable? / included_products_sheet_clickable?.
# - also makes headless extraction include accessory grids, not only .pipf-upsell-modal.
#
# Usage from Rails project root:
#   ruby -c fix_pipf_accessories_try_all_candidates_v2.rb
#   ruby fix_pipf_accessories_try_all_candidates_v2.rb
#   ruby -c app/lib/pl_details_fetcher.rb

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

method_marker = "PlDetailsFetcher.try_open_accessories_modal!: trying all visible accessories candidates"
if src.include?(method_marker)
  puts "Already patched: robust accessories candidate loop is present."
else
  new_method = <<~'RUBY'
    def try_open_accessories_modal!(browser)
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: trying all visible accessories candidates"

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
        sleep(0.7)
      rescue => e
        Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: close existing modal failed: #{e.message}"
      end

      result = browser.evaluate(<<~'JS')
        async function() {
          const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

          const hasAccessories = () => {
            return document.querySelector(".pipf-upsell-modal") !== null ||
              document.querySelectorAll(".pipf-upsell-modal [data-product-number]").length > 0 ||
              document.querySelectorAll("[class*='upsell'] [data-product-number], [class*='accessories'] [data-product-number]").length > 0;
          };

          const collect = () => {
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

            const seen = new Set();

            return Array.from(document.querySelectorAll(selectors)).filter((el) => {
              if (!isVisible(el)) return false;

              const haystack = textOf(el);
              if (!markerRe.test(haystack)) return false;
              if (badRe.test(haystack)) return false;

              const key = [el.tagName, haystack.slice(0, 120), el.getAttribute("href") || "", el.className || ""].join("|");
              if (seen.has(key)) return false;
              seen.add(key);
              return true;
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
          };

          const clickElement = async (el) => {
            const innerClickable = el.matches("button,a,[role='button']") ? el : el.querySelector("button,a,[role='button']");
            const target = innerClickable || el;

            target.scrollIntoView({ block: "center", inline: "center" });
            await sleep(250);

            try {
              target.click();
            } catch (e) {
              target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
            }

            for (let i = 0; i < 14; i += 1) {
              await sleep(350);
              if (hasAccessories()) return true;
            }

            return false;
          };

          if (hasAccessories()) {
            return {
              clicked: false,
              opened: true,
              reason: "already_present",
              tried: [],
              skus: Array.from(document.querySelectorAll("[data-product-number]")).map((el) => el.getAttribute("data-product-number")).filter(Boolean)
            };
          }

          const scrollPoints = [0.0, 0.25, 0.45, 0.65, 0.85, 1.0];
          const tried = [];

          for (const point of scrollPoints) {
            window.scrollTo(0, Math.floor(document.body.scrollHeight * point));
            await sleep(500);

            const candidates = collect();
            for (const candidate of candidates) {
              const label = textOf(candidate).slice(0, 180);
              tried.push(label);

              if (await clickElement(candidate)) {
                return {
                  clicked: true,
                  opened: true,
                  reason: "opened",
                  clickedText: label,
                  tried: tried.slice(0, 20),
                  skus: Array.from(document.querySelectorAll("[data-product-number]")).map((el) => el.getAttribute("data-product-number")).filter(Boolean)
                };
              }
            }
          }

          return {
            clicked: tried.length > 0,
            opened: false,
            reason: "not_opened",
            tried: tried.slice(0, 30),
            skus: Array.from(document.querySelectorAll("[data-product-number]")).map((el) => el.getAttribute("data-product-number")).filter(Boolean)
          };
        }
      JS

      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: result=#{result.inspect}"

      !!(result && result["opened"])
    rescue => e
      Rails.logger.debug "PlDetailsFetcher.try_open_accessories_modal!: #{e.class} - #{e.message}"
      false
    end

  RUBY

  if (start_idx = src.index("  def try_open_accessories_modal!(browser)\n"))
    end_markers = [
      "  # В SSR есть кнопка открытия модалки аксессуаров",
      "  def accessories_modal_clickable?(doc)\n",
      "  def included_products_sheet_clickable?(doc)\n"
    ]

    end_idx = end_markers.filter_map { |m| src.index(m, start_idx) }.min
    abort "Found try_open_accessories_modal!, but could not find end marker after it." unless end_idx

    src = src[0...start_idx] + new_method + src[end_idx..]
  else
    insert_markers = [
      "  # В SSR есть кнопка открытия модалки аксессуаров",
      "  def accessories_modal_clickable?(doc)\n",
      "  def included_products_sheet_clickable?(doc)\n"
    ]

    insert_idx = insert_markers.filter_map { |m| src.index(m) }.min
    abort "Could not find insertion point for try_open_accessories_modal!." unless insert_idx

    src = src[0...insert_idx] + new_method + src[insert_idx..]
  end
end

# Make headless extraction include accessory grids too.
old_extract = <<~'RUBY'
      accessories_related = extract_related_products_from_accessories_modal(modal_doc)
      recommendation_related = extract_related_products_from_recommendation_panel(modal_doc)
      related = (Array(accessories_related) + Array(recommendation_related)).map(&:to_s).uniq
RUBY

new_extract = <<~'RUBY'
      accessories_related = extract_related_products_from_accessories_modal(modal_doc)
      accessories_grid_related = extract_related_products_from_accessories_grid(modal_doc)
      recommendation_related = extract_related_products_from_recommendation_panel(modal_doc)
      related = (Array(accessories_related) + Array(accessories_grid_related) + Array(recommendation_related)).map(&:to_s).uniq
RUBY

if src.include?(old_extract)
  src = src.sub(old_extract, new_extract)
elsif !src.include?("accessories_grid_related = extract_related_products_from_accessories_grid(modal_doc)")
  warn "WARNING: Could not patch related extraction block automatically. Please inspect around `accessories_related =`."
end

if src == original
  puts "No changes were needed."
  exit 0
end

backup = "#{path}.bak_accessories_try_all_v2_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Check:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n 'trying all visible accessories candidates\\|accessories_grid_related\\|try_open_accessories_modal!: result' app/lib/pl_details_fetcher.rb"
