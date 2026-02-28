class PromoCodeCategory < ApplicationRecord
  belongs_to :promo_code
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id

  validates :category_id, presence: true
end
