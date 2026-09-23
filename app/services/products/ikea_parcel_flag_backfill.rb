# frozen_string_literal: true

# Разовый проход: флаг посылки из API наличия IKEA (то же поле, что homeDelivery.isParcel
# на польской странице) и пересчёт delivery_cost.
# Пустой ответ по артикулу не затирает уже записанный флаг.
class Products::IkeaParcelFlagBackfill
  BATCH_SIZE = 20
  AVAILABILITY_URL = "https://api.salesitem.ingka.com/availabilities/ru/pl"
  SEED_PAGE = "https://www.ikea.com/pl/pl/p/tannforsen-szafka-wiszaca-jasnoszary-30535109/"

  def self.call(skus: nil)
    new(skus: skus).call
  end

  def initialize(skus: nil)
    @skus = Array(skus).map { |sku| sku.to_s.strip }.reject(&:blank?)
  end

  def call
    before = catalog_counts
    samples_before = sample_rows
    stats = Hash.new(0)
    @skipped_without_item = 0

    each_item_batch do |batch|
      stats[:batches] += 1
      flags = fetch_flags(batch.keys)
      stats[:api_rows] += flags.size

      batch.each do |item_no, products|
        parcel = flags[item_no]
        if parcel.nil?
          stats[:missing] += products.size
          next
        end

        products.each { |product| apply_flag(product, parcel, stats) }
      end

      if (stats[:batches] % 25).zero?
        Rails.logger.info("[IkeaParcel] batches=#{stats[:batches]} updated=#{stats[:updated]} true=#{stats[:parcel_true]} false=#{stats[:parcel_false]} missing=#{stats[:missing]}")
      end
    end

    stats[:skipped_without_item] = @skipped_without_item

    {
      stats: stats,
      before: before,
      after: catalog_counts,
      samples_before: samples_before,
      samples_after: sample_rows
    }
  end

  private

  attr_reader :skus

  def each_item_batch
    grouped = Hash.new { |hash, key| hash[key] = [] }
    scope.find_each do |product|
      item_no = item_no_for(product)
      if item_no.blank?
        @skipped_without_item += 1
        next
      end

      grouped[item_no] << product
      next if grouped.size < BATCH_SIZE

      yield grouped
      grouped = Hash.new { |hash, key| hash[key] = [] }
    end
    yield grouped if grouped.any?
  end

  def scope
    relation = Product.all
    return relation if skus.empty?

    aliases = skus.flat_map { |sku| RefreshPlPricesAndStockJob.pl_price_stock_lookup_skus(sku) }
    relation.where(sku: aliases.presence || skus)
  end

  def item_no_for(product)
    raw = product.item_no.presence || product.sku
    digits = raw.to_s.gsub(/\D/, "")
    digits.match?(/\A\d{8}\z/) ? digits : nil
  end

  def fetch_flags(item_nos)
    response = nil
    ProxyRotator.with_proxy_retry do |proxy_options|
      response = IkeaApiService.get(
        "#{AVAILABILITY_URL}?itemNos=#{item_nos.join(",")}",
        headers: { "x-client-id" => client_id, "Accept" => "application/json" },
        timeout: 30,
        **(proxy_options || {})
      )
    end

    unless response.code.to_i.between?(200, 299)
      raise "IKEA availability HTTP #{response.code} for #{item_nos.size} items"
    end

    flags = {}
    Array(response.parsed_response["availabilities"]).each do |row|
      item_no = row.dig("itemKey", "itemNo").to_s
      next if item_no.blank?

      parcel = row.dig("buyingOption", "homeDelivery", "availability", "parcel")
      flags[item_no] = parcel unless parcel.nil?
    end
    flags
  end

  def apply_flag(product, parcel, stats)
    stats[:updated] += 1
    stats[parcel ? :parcel_true : :parcel_false] += 1
    delivery_before = product.delivery_cost
    product.update_columns(is_parcel: parcel, updated_at: Time.current)
    product.is_parcel = parcel

    if product.delivery_cost_manual?
      stats[:manual_skipped] += 1
      return
    end

    product.recalculate_ikea_delivery!
    stats[:delivery_changed] += 1 if product.delivery_cost != delivery_before
  end

  def client_id
    @client_id ||= ENV["IKEA_CLIENT_ID"].presence || client_id_from_pl_page
  end

  def client_id_from_pl_page
    html = PlDetailsFetcher.new.send(:fetch_with_proxy, SEED_PAGE).to_s
    key = html[/ciaApiClientKey":"([^"]+)"/, 1]
    raise "IKEA client id is missing" if key.blank?

    key
  end

  def catalog_counts
    {
      parcel_nil: Product.where(is_parcel: nil).count,
      parcel_true: Product.where(is_parcel: true).count,
      parcel_false: Product.where(is_parcel: false).count,
      gls_point: Product.where(delivery_type: "gls_point").count,
      delivery_zero: Product.where(delivery_cost: 0).count
    }
  end

  def sample_rows
    list = skus.presence || %w[30535109 90581099]
    list.filter_map do |sku|
      product = Product.find_by(sku: sku)
      next if product.nil?

      price = PriceCalculationService.for_product(product)
      {
        sku: product.sku,
        is_parcel: product.is_parcel,
        delivery_cost: product.delivery_cost.to_s,
        delivery_type: product.delivery_type,
        price_byn: price[:card_price_byn].to_s
      }
    end
  end
end
