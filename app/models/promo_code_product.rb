class PromoCodeProduct < ApplicationRecord
  belongs_to :promo_code

  validates :product_sku, presence: true

  attr_accessor :csv_file, :category_id
end
