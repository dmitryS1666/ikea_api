# frozen_string_literal: true

# Только польский сайт: цена в злотых (PLN) и наличие (PlDetailsFetcher.shelf_snapshot),
# обновление канонической ссылки на товар. В БД пишутся только price, quantity, url (+ updated_at).
# Поле products.price — всегда в PLN для записей, обновлённых этим сервисом.
# Если страница PL недоступна (нет URL, 404, пустой HTML/снимок) — quantity принудительно 0.
class Products::PlPriceStockRefreshService
  def self.refresh!(product)
    new(product).refresh!
  end

  def initialize(product)
    @product = product
  end

  def refresh!
    pl_url = pl_page_url_for(product)
    if pl_url.blank?
      return apply_not_found_on_pl!(reason: :no_pl_url)
    end

    snap = shelf_snapshot_rescue_not_found(pl_url)
    if snap.blank? || (snap[:canonical_url].blank? && snap[:price].blank? && snap[:availability].blank?)
      qty = normalized_quantity(nil)
      changed = product.quantity != qty
      product.update_columns(quantity: qty, updated_at: Time.current)
      return { updated: changed, reason: :empty_snapshot }
    end

    quantity = normalized_quantity(snap[:availability])
    price = self.class.normalize_price(snap[:price])
    canonical = self.class.ensure_pl_pl_url(snap[:canonical_url].presence || pl_url)

    attrs = {
      quantity: quantity,
      url: canonical,
      updated_at: Time.current
    }
    attrs[:price] = price if price.present?

    price_changed = price.present? && product.price != price
    changed = product.quantity != quantity ||
      product.url.to_s != canonical ||
      price_changed

    product.update_columns(attrs)
    { updated: changed, price_updated: price_changed }
  end

  # Число в злотых (PLN), разделитель дробной части на странице PL — запятая или точка.
  def self.normalize_price(val)
    return nil if val.blank?

    p = val.is_a?(String) ? val.to_s.gsub(/[^\d,.]/, "").tr(",", ".").to_f : val.to_f
    p.positive? ? p.round(2) : nil
  end

  # HIGH_IN_STOCK / IN_STOCK / явное «в наличии» и любое положительное число со страницы → 999.
  # Нет NULL: при полном отсутствии данных — 0.
  def self.normalized_quantity(availability)
    av = availability.is_a?(Hash) ? availability.stringify_keys : {}
    status = (av["status"] || av[:status]).to_s.upcase

    return 999 if %w[HIGH_IN_STOCK IN_STOCK ONLINE_ONLY].include?(status)
    return 5 if %w[LOW_IN_STOCK LIMITED_STOCK].include?(status)
    return 0 if %w[OUT_OF_STOCK NOT_AVAILABLE UNAVAILABLE].include?(status)

    q = av["quantity"] || av[:quantity]
    if q.nil?
      st = (av["status"] || av[:status]).to_s.downcase
      return 999 if st == "available"
      return 0 if st == "unavailable"

      return 0
    end

    qi = q.to_i
    qi.positive? ? 999 : qi
  end

  def self.ensure_pl_pl_url(url)
    u = url.to_s.strip
    u = "https://www.ikea.com#{u}" unless u.start_with?("http")
    return u unless u.match?(/ikea\.com/i)

    u.sub(%r{https?://www\.ikea\.com/[^/]+/[^/]+}i, "https://www.ikea.com/pl/pl")
  end

  # Страница товара отсутствует (404) — как пустой ответ: остаток 0, без изменения url/price здесь.
  def self.http_not_found_error?(error)
    error.message.to_s.match?(/\b404\b/)
  end

  private

  attr_reader :product

  def shelf_snapshot_rescue_not_found(pl_url)
    PlDetailsFetcher.shelf_snapshot(pl_url)
  rescue StandardError => e
    raise e unless self.class.http_not_found_error?(e)

    Rails.logger.info "PlPriceStockRefreshService: PL page not found for sku=#{product.sku} url=#{pl_url}: #{e.message}"
    {}
  end

  def apply_not_found_on_pl!(reason:)
    qty = normalized_quantity(nil)
    changed = product.quantity != qty
    product.update_columns(quantity: qty, updated_at: Time.current)
    { updated: changed, reason: reason }
  end

  def normalized_quantity(availability)
    self.class.normalized_quantity(availability)
  end

  def pl_page_url_for(product)
    raw = product.url.to_s.strip
    if raw.present?
      full =
        if raw.start_with?("http")
          raw
        else
          path = raw.start_with?("/") ? raw : "/#{raw}"
          "https://www.ikea.com#{path}"
        end
      return self.class.ensure_pl_pl_url(full) if full.match?(/ikea\.com/i)
    end

    article = product.item_no.to_s.presence || product.sku.to_s.gsub(/\D/, "")
    return nil if article.blank?

    "https://www.ikea.com/pl/pl/p/-#{article}/"
  end
end
