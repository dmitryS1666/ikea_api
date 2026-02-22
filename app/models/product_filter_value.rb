class ProductFilterValue < ApplicationRecord
  belongs_to :product
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, inverse_of: :product_filter_values

  validates :parameter, presence: true
  validates :value_id, presence: true
  validates :value_id, uniqueness: { scope: [:product_id, :category_id, :parameter] }
end
