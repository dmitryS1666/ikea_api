# frozen_string_literal: true

# Создаёт в БД недостающие записи Product для артикулов из related/set/bundle/included/variants
# и связывает их с категорией (как в ParseProductsJob через CategoryProduct).
class Products::ReferencedProductsEnsureService
  ARTICLE_PATTERN = /\A\d{8}\z/.freeze

  def self.ensure_for!(product, category:)
    new(product: product, category: category).ensure!
  end

  def initialize(product:, category:)
    @product = product
    @category = category
  end

  def ensure!
    return unless category

    articles = collect_articles
    articles.each { |article| ensure_one!(article) }
  end

  private

  attr_reader :product, :category

  def collect_articles
    list = []
    list.concat Array(product.related_products).map(&:to_s)
    list.concat Array(product.set_items).map(&:to_s)
    list.concat Array(product.bundle_items).map(&:to_s)
    list.concat Array(product.included_products).map(&:to_s)
    list.concat product.normalized_variant_skus.map(&:to_s)
    list.filter_map { |s| normalize_article(s) }.uniq - [normalize_article(product.sku)].compact
  end

  def normalize_article(str)
    # В related_* иногда прилетают служебные slug-и (product-details-..., appearance и т.п.)
    # или ID категорий. Для дозагрузки связанных товаров берем только артикулы IKEA (8 цифр).
    s = str.to_s.gsub(/\D/, "")
    return nil unless s.match?(ARTICLE_PATTERN)
    s
  end

  def find_existing(article)
    return nil if article.blank?

    Product.find_by(item_no: article) ||
      Product.where("regexp_replace(upper(sku), '[^0-9A-Z]', '', 'g') = ?", article.upcase).first
  end

  def ensure_one!(article)
    existing = find_existing(article)
    if existing
      CategoryProduct.find_or_create_by!(product: existing, category_id: category.ikea_id)
      return
    end

    pl_url = "https://www.ikea.com/pl/pl/p/-#{article}/"
    p =
      Product.create!(
        sku: article,
        item_no: article,
        name: "IKEA #{article}",
        price: 0,
        url: pl_url,
        category_id: category.ikea_id
      )
    CategoryProduct.find_or_create_by!(product: p, category_id: category.ikea_id)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # гонка или дубликат SKU — игнорируем
  end
end
