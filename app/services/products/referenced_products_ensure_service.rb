# frozen_string_literal: true

# Связывает с категорией уже существующие Product по артикулам из related/set/variants.
# Элементы набора (included_products) не трогаем — они не из листинга и создаются IncludedProductsBootstrapService.
# Новые строки в БД не создаём — иначе сыплются пустые «IKEA 12345678» без карточки.
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
      CategoryProduct.find_or_create_by!(product: existing, category_id: category.ikea_id.to_s)
      return
    end

    Rails.logger.debug do
      "ReferencedProductsEnsureService: нет товара в БД для артикула #{article}, пропуск (не создаём заглушку)"
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # гонка при find_or_create — игнорируем
  end
end
