class Product < ApplicationRecord
  # Колонка убрана из БД; виртуальное чтение — ProductFullAttributesRuCompat (prepend в initializer to_prepare).
  self.ignored_columns += ["full_attributes_ru"]

  COLOR_PARAM = "f-colors".freeze
  SIZE_PARAMS = %w[
    f-measurement-buckets
    f-shape
  ].freeze

  # Валидации
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true

  # Ассоциации
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true

  has_many :category_products, dependent: :destroy
  has_many :categories, through: :category_products, source: :category

  has_many :product_filter_values, dependent: :delete_all

  has_one :seo_meta, as: :seoable, class_name: 'SeoMetum', dependent: :destroy
  accepts_nested_attributes_for :seo_meta, allow_destroy: true, update_only: true

  def primary_category
    category || categories.order(:name).first
  end

  # Scopes
  scope :active, -> { all }
  # Публичные списки: только позиции с положительным остатком (как в SimilarProductsService)
  scope :with_available_stock, -> { where('products.quantity > 0') }
  scope :bestsellers, -> { where(is_bestseller: true) }
  scope :new_arrivals, -> { where(is_new: true) }
  scope :popular, -> { where(is_popular: true) }
  scope :recommended, -> { where(is_recommended: true) }
  scope :with_category, -> { where.not(category_id: nil) }

  # Товары в категории по ikea_id: основная category_id и/или связь category_products
  scope :in_category_ikea_id, lambda { |ikea_id|
    ikea_id = ikea_id.to_s.strip
    next all if ikea_id.blank?

    linked_ids = CategoryProduct.where(category_id: ikea_id).select(:product_id)
    where(category_id: ikea_id).or(where(id: linked_ids))
  }

  # Локальные пути ещё указывают на jpg/jpeg/png (до конвертации в .webp в хранилище)
  scope :with_raster_local_images, lambda {
    where.not(local_images: [nil, "", "[]"])
      .where(
        "local_images ILIKE ? OR local_images ILIKE ? OR local_images ILIKE ?",
        "%.jpg%", "%.jpeg%", "%.png%"
      )
  }

  # Для джобы WebP по категории: растр в local_images ИЛИ есть remote images, но локально пусто / не webp / битый формат в JSON
  scope :needing_product_image_job_processing, lambda {
    needs_remote_sync = where.not(images: [nil, "", "[]"]).where(
      <<~SQL.squish
        (local_images IS NULL OR TRIM(local_images) = '' OR TRIM(local_images) = '[]')
        OR local_images ILIKE '%.jpg%' OR local_images ILIKE '%.jpeg%' OR local_images ILIKE '%.png%'
        OR (TRIM(COALESCE(local_images, '')) NOT IN ('', '[]') AND local_images NOT ILIKE '%.webp%')
      SQL
    )

    with_raster_local_images.or(needs_remote_sync)
  }

  # Фрагмент для поиска товаров по сохранённым путям или URL в JSON (без учёта регистра)
  scope :with_image_json_containing, lambda { |fragment|
    fragment = fragment.to_s.strip
    next all if fragment.blank?

    escaped = ActiveRecord::Base.sanitize_sql_like(fragment)
    where(
      "products.local_images ILIKE ? OR products.images ILIKE ?",
      "%#{escaped}%",
      "%#{escaped}%"
    )
  }

  scope :by_rating, -> { order(rating_weighted: :desc, rating_count: :desc, id: :asc) }
  scope :cheapest_first,  -> { order(Arel.sql('products.price ASC NULLS LAST, products.id ASC')) }
  scope :expensive_first, -> { order(Arel.sql('products.price DESC NULLS LAST, products.id DESC')) }

  # Сериализация массивов
  serialize :variants, coder: JSON
  serialize :related_products, coder: JSON
  serialize :set_items, coder: JSON
  serialize :bundle_items, coder: JSON
  serialize :included_products, coder: JSON
  serialize :images, coder: JSON
  serialize :local_images, coder: JSON
  serialize :videos, coder: JSON
  serialize :manuals, coder: JSON
  serialize :features, coder: JSON
  serialize :assembly_documents, coder: JSON

  before_save :cache_slug, if: -> { name_changed? || name_ru_changed? || cached_slug.blank? }
  before_validation :normalize_included_products!

  def slug
    cached_slug || generate_slug
  end

  # Callbacks
  before_save :calculate_delivery, if: :weight_changed?
  after_commit :enqueue_filters_reindex, on: [:create, :update]

  # Сырой sku в JSON иногда приходит массивом; у Array#to_s получается строка вида "["s1", "s2"]" — это мусор для БД.
  def self.expand_listing_skus_from_raw(raw)
    return [] if raw.blank? || raw.is_a?(Hash)

    Array(raw).filter_map { |s| s.to_s.strip.presence }
  end

  def normalized_variant_skus
    skus = []
    Array(variants).each do |variant|
      raw =
        case variant
        when Hash
          variant["sku"] || variant[:sku] || variant["value"] || variant[:value] || variant["id"] || variant[:id]
        when String, Integer
          variant
        end
      skus.concat(self.class.expand_listing_skus_from_raw(raw))
    end
    skus.uniq
  end

  def variant_products
    skus = ([sku.to_s] + normalized_variant_skus).uniq
    Product.where(sku: skus)
  end

  def filter_map
    product_filter_values.each_with_object(Hash.new { |h, k| h[k] = [] }) do |pfv, memo|
      next if pfv.parameter.blank? || pfv.value_id.blank?
      memo[pfv.parameter] << pfv.value_id
    end.transform_values(&:uniq)
  end

  def variant_group_type
    products = variant_products.to_a
    return nil if products.size < 2

    per_product_filters = products.index_with(&:filter_map)
    all_parameters = per_product_filters.values.flat_map(&:keys).uniq

    differing_parameters = all_parameters.select do |parameter|
      products.map { |p| Array(per_product_filters[p][parameter]).sort }.uniq.size > 1
    end

    return "size" if (differing_parameters & SIZE_PARAMS).any?
    return "color" if differing_parameters.include?(COLOR_PARAM)

    texts = products.map do |p|
      [p.small_desc_name, p.dimensions_ru, p.dimensions, p.package_dimensions].compact.join(" | ")
    end

    return "size" if texts.any? { |t| t.match?(/\b\d{2,4}\s?[xх]\s?\d{2,4}\b/i) || t.match?(/\b\d+[.,]?\d*\s?(см|mm|мм|cm|м)\b/i) }

    nil
  end

  def variant_label_for(parameter)
    value_id = Array(filter_map[parameter]).first
    return nil if value_id.blank?

    resolve_filter_label(parameter, value_id)
  end

  def resolve_filter_label(parameter, value_id)
    # 1. если есть category.available_filters — берем человекочитаемое значение оттуда
    category_filters =
      if primary_category.respond_to?(:available_filters)
        Array(primary_category.available_filters)
      else
        []
      end

    filter_block = category_filters.find do |f|
      key = f["parameter"] || f[:parameter] || f["key"] || f[:key]
      key.to_s == parameter.to_s
    end

    if filter_block.present?
      values = filter_block["values"] || filter_block[:values] || []
      matched = values.find do |v|
        vid = v["id"] || v[:id] || v["value_id"] || v[:value_id]
        vid.to_s == value_id.to_s
      end

      if matched.present?
        return matched["label"] || matched[:label] ||
               matched["name"] || matched[:name] ||
               matched["value"] || matched[:value]
      end
    end

    # 2. fallback: по value_id
    value_id.to_s
      .sub(/\A[A-Z_]+_/, "")
      .tr("_", " ")
      .downcase
      .presence
  end

  def variant_item_payload
    images = ProductLocalImages.expand_paths(local_images)

    {
      sku: sku,
      name_ru: name_ru,
      small_desc_name: small_desc_name,
      price: price&.to_s,
      quantity: quantity || 999,
      images: images
    }
  end

  def normalized_variants_for_api
    # Сначала пробуем использовать сохраненный тип из БД
    type = variant_type.presence || variant_group_type
    
    # Если мы сохранили данные в variants_payload (в IkeaLvProductVariantsService), 
    # мы можем использовать их напрямую
    if Product.column_names.include?("variants_payload") && variants_payload.present?
      begin
        payload = JSON.parse(variants_payload)
        
        # Обработка как массива (новая структура) или объекта (старая)
        data_to_process = payload.is_a?(Array) ? payload : [payload]
        
        # variants_payload приходит с польской витрины, поэтому цену варианта
        # трактуем как PLN независимо от текущего URL товара.
        pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
        buffer = PriceCalculationService.exchange_rate_buffer

        variant_skus =
          data_to_process.flat_map do |vg|
            Array(vg.deep_symbolize_keys[:data]).filter_map { |v| v.dig(:item, :sku).presence || v.dig(:item, 'sku').presence }.map(&:to_s)
          end.uniq
        variants_by_sku = variant_skus.empty? ? {} : Product.where(sku: variant_skus).index_by(&:sku)
        
        processed_payload = data_to_process.map do |variant_group|
          group = variant_group.deep_symbolize_keys
          group[:data].each do |variant|
            item = variant[:item]
            original_price = item[:price].to_f
            sku_v = item[:sku].presence || item['sku'].presence
            rec = sku_v.present? ? variants_by_sku[sku_v.to_s] : nil
            w_kg = (rec || self).weight.to_f
            d_pln = (rec || self).delivery_cost.to_f

            if original_price > 0
              price_byn = PriceCalculationService.product_price_byn(
                original_price,
                weight_kg: w_kg,
                delivery_pln: d_pln,
                pln_rate: pln_rate,
                buffer: buffer
              )
              item[:price_byn] = ActionController::Base.helpers.number_with_delimiter(price_byn, delimiter: ' ')
            else
              item[:price_byn] = nil
            end
          end
          # Текущий артикул первым в группе (остальной порядок как в HTML)
          group[:data] =
            Array(group[:data]).sort_by.with_index do |variant, idx|
              sku_v = variant.dig(:item, :sku).to_s.downcase
              mine = sku_v == sku.to_s.downcase ? 0 : 1
              [mine, idx]
            end
          group
        end

        normalize_variant_payload_images!(processed_payload)

        return payload.is_a?(Array) ? processed_payload : processed_payload.first
      rescue JSON::ParserError
      end
    end

    return nil if type.blank?

    products = variant_products.to_a
    return nil if products.size < 2

    data =
      case type
      when "color"
        products.map do |product|
          label = product.variant_label_for(COLOR_PARAM)
          next if label.blank?

          {
            color: label,
            item: product.variant_item_payload
          }
        end.compact
      when "size"
        products.map do |product|
          label =
            product.variant_label_for("f-measurement-buckets") ||
            product.variant_label_for("f-shape") ||
            product.small_desc_name.presence ||
            product.dimensions_ru.presence ||
            product.dimensions.presence

          next if label.blank?

          {
            size: label,
            item: product.variant_item_payload
          }
        end.compact
      else
        []
      end

    return nil if data.size < 2

    {
      type: type,
      data: data
    }
  end

  private

  # variants_payload: раскрыть as: в /images/products/..., убрать ikea.com при наличии локальных путей
  def normalize_variant_payload_images!(processed_payload)
    Array(processed_payload).each do |group|
      data = group[:data] || group["data"]
      Array(data).each do |variant|
        item = variant[:item] || variant["item"]
        next unless item

        raw = item[:images] || item["images"]
        next if raw.blank?

        normalized = ProductLocalImages.normalize_api_image_array(raw)
        item[:images] = normalized
        item["images"] = normalized
      end
    end
  end

  def cache_slug
    self.cached_slug = generate_slug
  end

  def generate_slug
    source = name_ru.presence || name.presence || sku
    SlugifyService.call(source)
  end

  def calculate_delivery
    # Логика расчета доставки
    # Аналогично deliveryService.js
  end

  def enqueue_filters_reindex
    return unless saved_change_to_full_attributes? ||
                  saved_change_to_price? ||
                  saved_change_to_rating_avg? ||
                  saved_change_to_rating_weighted? ||
                  saved_change_to_is_bestseller? ||
                  saved_change_to_is_new? ||
                  saved_change_to_is_popular? ||
                  saved_change_to_is_recommended? ||
                  saved_change_to_quantity? ||
                  saved_change_to_collection? ||
                  saved_change_to_features?

    category_ids = categories.pluck(:ikea_id)
    category_ids << category_id if category_id.present?
    category_ids = category_ids.compact.uniq
    return if category_ids.empty?

    ReindexProductFiltersJob.perform_later(id, category_ids)
  end

  def normalize_included_products!
    self.included_products =
      case included_products
      when nil
        []
      when Array
        included_products
      when String
        if included_products.strip.start_with?('[')
          begin
            JSON.parse(included_products)
          rescue JSON::ParserError
            included_products.split(/[\n,\r;]+/)
          end
        else
          included_products.split(/[\n,\r;]+/)
        end
      else
        Array(included_products)
      end
        .flatten
        .filter_map do |item|
          if item.is_a?(Hash)
            item["sku"] || item[:sku] || item["item_no"] || item[:item_no]
          else
            item.to_s.gsub(/[\[\]\"]/, '').strip.presence
          end
        end
        .uniq
  end
end

# После полного определения класса: prepend перекрывает сгенерированный AR-геттер / _read_attribute.
unless Product.ancestors.include?(ProductFullAttributesRuCompat)
  Product.prepend(ProductFullAttributesRuCompat)
end
