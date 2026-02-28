class FavoriteItem < ApplicationRecord
  belongs_to :favorite
  belongs_to :product, foreign_key: :product_sku, primary_key: :sku, optional: true

  validates :product_sku, presence: true
  validates :product_sku, uniqueness: { scope: :favorite_id }
end
