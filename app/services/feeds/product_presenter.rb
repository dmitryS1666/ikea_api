require "cgi"
require "json"

module Feeds
  class ProductPresenter
    DESCRIPTION_MAX_LENGTH = 5000

    attr_reader :product, :settings, :pricing_context, :active_promos

    def initialize(product:, settings:, pricing_context: nil, active_promos: nil, category_index: nil)
      @product = product
      @settings = settings
      @pricing_context = pricing_context || {}
      @active_promos = active_promos
      @category_index = category_index
    end

    def valid?
      base_url.present? &&
        link_url.present? &&
        image_url.present? &&
        price_amount.present? &&
        currency.present? &&
        category_id.present?
    end

    def id
      product.sku.presence || product.unique_id.presence || product.id
    end

    def title
      [
        product.name_ru,
        product.name,
        product.collection
      ].find(&:present?) || "Product #{id}"
    end

    def description
      base = plain_text(
        [
          product.content_ru,
          product.short_description_ru,
          product.good_info_ru,
          product.material_info_ru,
          product.content,
          product.short_description,
          product.good_info,
          product.material_info
        ].find(&:present?)
      )

      parts = []
      parts << base if base.present?
      parts << applicability_block if applicability_block.present?
      text = parts.join("\n\n").presence || title
      text.truncate(DESCRIPTION_MAX_LENGTH)
    end

    def link_url
      return unless product.url.present? && base_url.present?

      if product.url =~ /\Ahttps?:\/\//
        product.url
      else
        path = product.url.start_with?("/") ? product.url : "/#{product.url}"
        "#{base_url}#{path}"
      end
    end

    def image_url
      image_urls.first
    end

    def additional_image_urls
      image_urls.drop(1).first(10)
    end

    def price_amount
      @price_amount ||= begin
        if byn_currency?
          storefront_price_byn
        else
          product.price&.to_d
        end
      end
    end

    def sale_price_amount
      return @sale_price_amount if defined?(@sale_price_amount)

      @sale_price_amount =
        if price_amount.blank? || best_promo.blank?
          nil
        else
          discount = CartPricingService.calculate_unit_discount_byn(
            best_promo,
            price_amount,
            pricing_context[:pln_rate],
            pricing_context[:buffer]
          )
          next_price = (price_amount.to_d - discount.to_d).round(2)
          next_price.positive? && next_price < price_amount.to_d ? next_price : nil
        end
    end

    def currency
      settings.currency_default&.upcase
    end

    def availability_key
      return @availability_key if defined?(@availability_key)

      qty = product.quantity
      status =
        if qty.present?
          qty.to_i.positive? ? "in_stock" : "out_of_stock"
        else
          "in_stock"
        end

      @availability_key = status
    end

    def availability_for_google
      settings.availability_mapping_hash[availability_key] || availability_key
    end

    def available_for_yandex?
      return true if settings.include_out_of_stock?

      availability_key == "in_stock"
    end

    def category
      product.category
    end

    def category_id
      category&.ikea_id.presence || product.category_id
    end

    def product_type
      return @product_type if defined?(@product_type)

      cat = category
      return @product_type = nil unless cat

      ancestor_ids = Category.normalize_parent_ids(cat.parent_ids)
      ordered_ids = (ancestor_ids + [cat.ikea_id]).compact.uniq
      names = ordered_ids.filter_map do |cid|
        c = category_by_id(cid)
        next unless c

        c.try(:translated_name).presence || c.name
      end

      @product_type = names.join(" > ").presence || cat.name
    end

    def brand
      settings.store_platform_brand
    end

    def mpn
      product.item_no.presence || product.public_sku.presence || product.sku.presence
    end

    def gtin
      extract_gtin
    end

    def material
      plain_text(
        [
          flatten_text(product.materials_ru),
          flatten_text(product.materials),
          product.material_info_ru,
          product.material_info
        ].find(&:present?)
      )&.truncate(200)
    end

    def color
      label = product.variant_label_for(Product::COLOR_PARAM)
      return label if label.present?

      return product.small_desc_name.to_s.strip.presence if color_variant?

      nil
    end

    def size
      Product::SIZE_PARAMS.each do |param|
        label = product.variant_label_for(param)
        return label if label.present?
      end

      return product.small_desc_name.to_s.strip.presence if size_variant?

      nil
    end

    def pattern
      return unless pattern_variant?

      product.small_desc_name.to_s.strip.presence || color
    end

    def item_group_id
      skus = ([product.sku.to_s] + product.normalized_variant_skus.map(&:to_s)).reject(&:blank?).uniq.sort
      return nil if skus.size < 2

      skus.first
    end

    def custom_label_0
      best_promo&.code
    end

    def custom_label_1
      if product.is_bestseller?
        "bestseller"
      elsif product.is_popular?
        "popular"
      elsif product.is_new?
        "new"
      elsif product.is_recommended?
        "recommended"
      end
    end

    def custom_label_2
      product.collection.presence
    end

    def custom_label_3
      category&.try(:translated_name).presence || category&.name
    end

    def custom_label_4
      if best_promo.present?
        "promo"
      elsif availability_key == "out_of_stock"
        "out_of_stock"
      else
        "regular"
      end
    end

    private

    def byn_currency?
      currency == "BYN"
    end

    def storefront_price_byn
      pln = product.price.to_f
      return nil unless pln.positive?

      pln_rate = pricing_context[:pln_rate] || ExchangeRate.fetch_or_create("PLN")&.rate_per_unit.to_f
      return nil unless pln_rate.positive?

      buffer = pricing_context[:buffer] || PriceCalculationService.exchange_rate_buffer

      PriceCalculationService.product_storefront_price_byn(
        pln,
        weight_kg: product.packaging_weight_kg.to_f,
        delivery_pln: product.delivery_cost.to_f,
        pln_rate: pln_rate,
        buffer: buffer
      )&.to_d
    end

    def best_promo
      return @best_promo if defined?(@best_promo)

      promos = Array(active_promos)
      if promos.empty?
        @best_promo = nil
        return @best_promo
      end

      cat_ids = ([product.category_id] + product.category_products.map(&:category_id)).compact.uniq
      applicable = promos.select { |promo| promo.applies_to_sku?(product.sku, cat_ids) }
      @best_promo = applicable.max_by do |p|
        p.discount_type == "percent" ? p.discount_value : (p.discount_value.to_f / 4.0)
      end
    end

    def applicability_block
      return @applicability_block if defined?(@applicability_block)

      lines = []
      lines << "Коллекция/серия: #{product.collection}" if product.collection.present?
      lines << "Категория: #{product_type}" if product_type.present?
      lines << "Цвет: #{color}" if color.present?
      lines << "Размер: #{size}" if size.present?
      lines << "Узор: #{pattern}" if pattern.present?
      lines << "Материал: #{material}" if material.present?
      if product.small_desc_name.present? && product.small_desc_name != color && product.small_desc_name != size
        lines << "Вариант: #{product.small_desc_name}"
      end

      @applicability_block =
        if lines.any?
          "Применимость (для поиска и объявлений):\n#{lines.join("\n")}"
        end
    end

    def color_variant?
      return true if product.variant_type.to_s == "color"
      return true if product.variant_label_for(Product::COLOR_PARAM).present?

      false
    end

    def size_variant?
      return true if product.variant_type.to_s == "size"

      Product::SIZE_PARAMS.any? { |param| product.variant_label_for(param).present? }
    end

    def pattern_variant?
      type = product.variant_type.to_s
      type == "pattern" || type.include?("pattern")
    end

    def extract_gtin
      full = product.full_attributes
      return nil unless full.is_a?(Hash)

      candidates = [
        full["gtin"], full[:gtin],
        full["gtin13"], full[:gtin13],
        full["ean"], full[:ean],
        full["barcode"], full[:barcode],
        full.dig("offers", "gtin"),
        full.dig("offers", "gtin13"),
        full.dig("product", "gtin")
      ]
      value = candidates.find { |v| v.present? }&.to_s&.gsub(/\D/, "")
      return value if value.present? && value.length.between?(8, 14)

      nil
    end

    def flatten_text(value)
      return nil if value.blank?
      return value if value.is_a?(String)

      if value.is_a?(Hash)
        value.values.filter_map { |v| flatten_text(v) }.join("; ").presence
      elsif value.is_a?(Array)
        value.filter_map { |v| flatten_text(v) }.join("; ").presence
      else
        value.to_s
      end
    end

    def plain_text(value)
      return nil if value.blank?

      text = value.to_s
      text = ActionController::Base.helpers.strip_tags(text)
      text = CGI.unescapeHTML(text)
      text.gsub(/\s+/, " ").strip.presence
    end

    def base_url
      settings.base_url_root
    end

    def category_by_id(cid)
      return @category_index[cid] if @category_index

      Category.find_by(ikea_id: cid)
    end

    def image_urls
      @image_urls ||= begin
        sources = Array(parse_images(product.images)) + Array(parse_images(product.local_images))
        sources = sources.flatten
        sources.map { |url| normalize_url(url) }.compact.uniq
      end
    end

    def parse_images(value)
      return [] if value.blank?

      if value.is_a?(String)
        JSON.parse(value)
      else
        value
      end
    rescue JSON::ParserError
      Array(value)
    end

    def normalize_url(value)
      return nil unless value.present?

      candidate = value.to_s.strip
      return nil if candidate.blank?
      return candidate if candidate =~ /\Ahttps?:\/\//
      return nil unless base_url.present?

      path = candidate.start_with?("/") ? candidate : "/#{candidate}"
      "#{base_url}#{path}"
    end
  end
end
