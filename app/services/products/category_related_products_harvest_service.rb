# frozen_string_literal: true

module Products
  # Собирает единый список SKU для категории по первому и последнему товару с PL-листинга:
  # панели «с этим покупают» / related + аксессуары (если появились при загрузке карточки).
  class CategoryRelatedProductsHarvestService
    def self.call(category:, listing_rows:)
      new(category: category, listing_rows: listing_rows).call
    end

    # Добавляет SKU аксессуаров, найденные при актуализации конкретной карточки товара,
    # в общий список related_products категории. Так все товары категории получают один
    # общий, постепенно обогащаемый список аксессуаров.
    def self.merge_skus!(category:, skus:, exclude_skus: [], anchor_sku: nil)
      new(category: category, listing_rows: []).merge_skus!(
        skus,
        exclude_skus: exclude_skus,
        anchor_sku: anchor_sku
      )
    end

    def initialize(category:, listing_rows:)
      @category = category
      @rows = Array(listing_rows)
    end

    def call
      return if @category.blank? || @rows.empty?

      anchor_data = anchor_rows_with_urls
      return if anchor_data.empty?

      skus = []
      anchor_data.each do |h|
        chunk = PlDetailsFetcher.related_skus_bundle_for_product_url(h[:url], scope_sku: h[:listing_sku])
        skus.concat(chunk)
      end

      record = merge_skus!(
        skus,
        exclude_skus: anchor_data.filter_map { |h| h[:listing_sku] },
        anchor_sku: anchor_data.first[:listing_sku]
      )
      record.assign_attributes(
        anchor_first_sku: anchor_data.first[:listing_sku].to_s,
        anchor_last_sku: (anchor_data.size > 1 ? anchor_data.last[:listing_sku] : nil)&.to_s
      )
      record.save!
      Rails.logger.info(
        "CategoryRelatedProductsHarvestService: category=#{@category.ikea_id} anchors=#{anchor_data.size} " \
        "related_skus=#{skus.size}"
      )
    end

    def merge_skus!(skus, exclude_skus: [], anchor_sku: nil)
      incoming = normalize_skus(skus)
      return existing_record if incoming.empty?

      excluded_articles = normalize_skus(exclude_skus).filter_map { |sku| canonical_article(sku) }.uniq
      incoming.reject! { |sku| excluded_articles.include?(canonical_article(sku)) }
      return existing_record if incoming.empty?

      record = existing_record
      current = normalize_skus(record.related_products)
      merged = (current + incoming).uniq
      record.assign_attributes(related_products: merged)
      record.anchor_first_sku ||= anchor_sku.to_s if anchor_sku.present?
      record.save!
      record
    end

    private

    def existing_record
      CategoryRelatedProductList.find_or_initialize_by(category_id: @category.ikea_id.to_s)
    end

    def normalize_skus(values)
      Array(values)
        .map(&:to_s)
        .map { |s| s.gsub(/[^0-9a-z]/i, "") }
        .select { |s| s.match?(/\A\d{8}\z/i) || s.match?(/\As\d{8}\z/i) }
        .uniq
    end

    def anchor_rows_with_urls
      rows = []
      rows << @rows.first
      rows << @rows.last if @rows.size > 1
      rows.uniq!

      rows.filter_map do |row|
        h = normalize_row(row)
        listing_sku = Products::ListingSkuResolver.coerce_listing_identifier(h["id"] || h["sku"])
        next if listing_sku.blank?

        url = pl_pip_url_from_row(h)
        next if url.blank?

        { row: row, url: url, listing_sku: listing_sku.to_s }
      end
    end

    def normalize_row(row)
      return {} unless row.is_a?(Hash)

      row.stringify_keys
    end

    def pl_pip_url_from_row(h)
      pip = h["pipUrl"].presence || h["url"].presence
      return nil if pip.blank?

      path = pip.to_s.strip
      path = path.gsub(%r{/lt/ru/}, "/pl/pl/")
      if path.start_with?("http://", "https://")
        path
      else
        "https://www.ikea.com#{path.start_with?('/') ? path : "/#{path}"}"
      end
    end

    def canonical_article(listing_sku)
      listing_sku.to_s.gsub(/[^0-9a-z]/i, "").sub(/\As/i, "")[/\d{8}/]
    end
  end
end
