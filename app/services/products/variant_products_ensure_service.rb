# frozen_string_literal: true

module Products
  # SKU из variants_payload (цвет/размер) — отдельные Product в БД с полной карточкой.
  # extra_skus: depth-1 listing комплектации (gprDescription.variants), без рекурсии.
  # enqueue_jobs: false на актуализации категории — иначе каждый вариант снова
  # тянет PIP-варианты через EnrichVariantProductJob.
  class VariantProductsEnsureService
    PL_STUB_URL = "https://www.ikea.com/pl/pl/p/-%{sku}/"

    def self.ensure!(product, category:, extra_skus: [], enqueue_jobs: true, include_column_skus: true)
      new(
        product: product,
        category: category,
        extra_skus: extra_skus,
        enqueue_jobs: enqueue_jobs,
        include_column_skus: include_column_skus
      ).ensure!
    end

    def initialize(product:, category:, extra_skus: [], enqueue_jobs: true, include_column_skus: true)
      @product = product
      @category = category
      @extra_skus = Array(extra_skus)
      @enqueue_jobs = enqueue_jobs
      @include_column_skus = include_column_skus
    end

    def ensure!
      return unless @category
      # Убираем жесткую привязку только к variants_payload, так как варианты могут быть и в обычном поле variants
      return if @product.variants_payload.blank? && @product.normalized_variant_skus.blank? && extra_skus.blank?

      variants = collect_skus.filter_map { |sku| process_variant_sku(sku) }
      sync_variant_group_links!(([product] + variants).uniq(&:id))
    end

    private

    attr_reader :product, :category, :extra_skus

    def collect_skus
      from_payload = self.class.variant_skus_from_variants_payload(product.variants_payload)
      from_column = @include_column_skus ? product.normalized_variant_skus.map(&:to_s) : []
      extra = extra_skus.map(&:to_s)
      parent_aliases = ListingSkuResolver.aliases(product.sku).map(&:to_s)

      (from_payload + from_column + extra)
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .reject { |sku| parent_aliases.include?(sku) }
    end

    def process_variant_sku(listing_sku)
      existing = ListingSkuResolver.find_product(listing_sku)
      if existing
        sync_variant_categories!(existing)
        if incomplete_product?(existing)
          enqueue_variant_job(existing.sku)
        end
        return existing
      end

      stub = create_variant_product_after_pl_fetch(listing_sku)
      return if stub.blank?

      sync_variant_categories!(stub)
      enqueue_variant_job(stub.sku)
      stub
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn "VariantProductsEnsureService sku=#{listing_sku}: #{e.class} #{e.message}"
      nil
    end

    def incomplete_product?(p)
      return true if p.price.blank? || p.price.to_f <= 0
      return true if p.weight.blank? && p.dimensions.blank?
      return true if p.materials.blank? && poor_full_attributes?(p)
      return true if p.content.to_s.strip.blank? && p.short_description.to_s.strip.blank?
      return true if placeholder_name?(p)

      false
    end

    def poor_full_attributes?(p)
      fa = p.full_attributes
      return true unless fa.is_a?(Hash)

      fa = fa.deep_stringify_keys
      detailed = fa["detailed_info"]
      return false if detailed.is_a?(Hash) && detailed.any?

      skip = %w[measurements_modal product_details_modal measurements_modal_extracted_at product_details_modal_extracted_at]
      fa.except(*skip).blank?
    end

    def placeholder_name?(p)
      p.name.to_s.match?(/\AIKEA\s+(s?)\d{8}\z/i)
    end

    def stub_still_empty_after_fetch?(p)
      placeholder_name?(p) || p.name.to_s.strip.blank?
    end

    def discard_variant_stub!(product, cid)
      return unless product&.persisted?

      product.category_products.where(category_id: cid).delete_all
      product.update_columns(category_id: nil) if product.category_id.to_s == cid.to_s
      product.destroy!
    end

    # Минимальная строка + сразу PL/LT fetch; если карточка не подтянулась — удаляем, без мусора в списках.
    def create_variant_product_after_pl_fetch(listing_sku)
      sku = listing_sku.to_s.strip
      article = sku.match(/(\d{8})/)&.captures&.first
      if article.blank?
        Rails.logger.warn "VariantProductsEnsureService: skip variant, no 8-digit article in #{sku.inspect}"
        return nil
      end

      cid = category.ikea_id.to_s
      url = format(PL_STUB_URL, sku: sku.delete("."))
      product = nil
      product =
        Product.create!(
          sku: sku,
          item_no: article,
          name: "IKEA #{sku}",
          price: 0,
          quantity: 0,
          url: url,
          category_id: cid
        )

      # LT — донор текстов; если LT нет — полная карточка с PL без обязательного OpenAI.
      Products::ExtendedAttributesFetchService.fetch_for_product(
        product,
        force_ai_translation: false,
        fallback_pl_when_lt_missing: true
      )
      product.reload

      if stub_still_empty_after_fetch?(product)
        discard_variant_stub!(product, cid)
        Rails.logger.info "VariantProductsEnsureService: отброшен пустой вариант sku=#{sku} (нет данных с PL/LT)"
        return nil
      end

      product
    rescue StandardError => e
      discard_variant_stub!(product, cid) if product&.persisted?
      Rails.logger.warn "VariantProductsEnsureService: variant sku=#{listing_sku} #{e.class}: #{e.message}"
      nil
    end

    def sync_variant_group_links!(products)
      records = Array(products).compact.uniq(&:id)
      return if records.size < 2

      records.each do |record|
        sibling_skus = records.reject { |p| p.id == record.id }.map { |p| p.sku.to_s }.reject(&:blank?).uniq
        next if sibling_skus.sort == record.normalized_variant_skus.map(&:to_s).sort

        record.update_columns(
          # Product сериализует колонку через JSON coder; массив нельзя
          # предварительно превращать в JSON-строку.
          variants: sibling_skus,
          updated_at: Time.current
        )
      end

      sync_single_axis_payload!(records)
    end

    # Для обычной одноосевой группы (только color либо только size) payload
    # должен быть одинаковым у каждой карточки. Раньше синхронизировался только
    # список SKU, поэтому часть карточек отвечала variants: null.
    #
    # Комбинированные color + size payload здесь не копируем: у них список
    # размеров может зависеть от выбранного цвета.
    def sync_single_axis_payload!(records)
      candidates = records.filter_map { |record| single_axis_payload(record.variants_payload) }
      candidate = candidates.max_by { |item| item[:skus].size }
      return unless candidate
      return unless records.all? { |record| payload_contains_sku?(candidate[:skus], record.sku) }

      canonical_payload = JSON.generate(candidate[:groups])
      canonical_type = candidate[:type]

      records.each do |record|
        updates = {}
        updates[:variants_payload] = canonical_payload if record.variants_payload.to_s != canonical_payload
        if Product.column_names.include?("variant_type") && record.variant_type.to_s != canonical_type
          updates[:variant_type] = canonical_type
        end
        next if updates.empty?

        updates[:updated_at] = Time.current
        record.update_columns(updates)
      end
    end

    def single_axis_payload(raw)
      return nil if raw.blank?

      parsed = JSON.parse(raw.to_s)
      groups = parsed.is_a?(Array) ? parsed : [parsed]
      return nil unless groups.size == 1 && groups.first.is_a?(Hash)

      group = groups.first.deep_stringify_keys
      type = group["type"].to_s
      return nil unless %w[color size].include?(type)

      rows = Array(group["data"])
      return nil if rows.size < 2

      skus = rows.filter_map do |row|
        next unless row.is_a?(Hash)

        item = row["item"] || row[:item]
        next unless item.is_a?(Hash)

        item["sku"] || item[:sku]
      end.map(&:to_s).reject(&:blank?).uniq

      return nil if skus.size < 2

      { groups: groups, type: type, skus: skus }
    rescue JSON::ParserError, TypeError
      nil
    end

    def payload_contains_sku?(payload_skus, record_sku)
      record_aliases = ListingSkuResolver.aliases(record_sku).map(&:to_s)
      Array(payload_skus).any? do |payload_sku|
        (record_aliases & ListingSkuResolver.aliases(payload_sku).map(&:to_s)).any?
      end
    end

    def enqueue_variant_job(sku)
      return unless @enqueue_jobs

      EnrichVariantProductJob.enqueue_once(sku: sku, category_ikea_id: category.ikea_id)
    end

    def sync_variant_categories!(variant)
      category_ids = variant_category_ids_to_link
      category_ids.each do |cid|
        CategoryProduct.find_or_create_by!(product: variant, category_id: cid)
      end

      primary_category_id = product.category_id.presence || category.ikea_id.to_s
      return if primary_category_id.blank? || variant.category_id.to_s == primary_category_id.to_s

      variant.update_columns(category_id: primary_category_id, updated_at: Time.current)
    end

    def variant_category_ids_to_link
      @variant_category_ids_to_link ||= begin
        from_parent = product.category_products.pluck(:category_id)
        from_parent << product.category_id
        from_parent << category.ikea_id
        from_parent.compact.map(&:to_s).map(&:strip).reject(&:blank?).uniq
      end
    end

    class << self
      def variant_skus_from_variants_payload(variants_payload)
        raw = variants_payload
        return [] if raw.blank?

        data = JSON.parse(raw.to_s)
        groups = data.is_a?(Array) ? data : [data]
        skus = []
        groups.each do |g|
          next unless g.is_a?(Hash)

          g = g.deep_stringify_keys
          Array(g["data"]).each do |row|
            next unless row.is_a?(Hash)

            row = row.deep_stringify_keys
            item = row["item"]
            next unless item.is_a?(Hash)

            item = item.deep_stringify_keys
            Product.expand_listing_skus_from_raw(item["sku"]).each { |s| skus << s }
          end
        end
        skus.uniq
      rescue JSON::ParserError
        []
      end
    end
  end
end
