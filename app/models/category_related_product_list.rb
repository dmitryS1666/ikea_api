# frozen_string_literal: true

# Единый список related_products для всех товаров категории (витрина PL: «с этим покупают» + аксессуары).
class CategoryRelatedProductList < ApplicationRecord
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, inverse_of: :category_related_product_list

  validates :category_id, presence: true, uniqueness: true

  def self.skus_array_for_category_id(category_id)
    return [] if category_id.blank?

    row = find_by(category_id: category_id.to_s.strip)
    return [] unless row

    Array(row.related_products).map(&:to_s).map(&:strip).reject(&:blank?)
  end

  # Порядок: основная category_id, затем прочие привязки каталога.
  def self.skus_for_product(product)
    ids = []
    ids << product.category_id if product.category_id.present?
    if product.respond_to?(:categories)
      product.categories.each do |c|
        next if c.ikea_id.blank?

        ids << c.ikea_id unless ids.include?(c.ikea_id)
      end
    end

    ids.each do |cid|
      skus = skus_array_for_category_id(cid)
      return skus if skus.any?
    end

    []
  end
end
