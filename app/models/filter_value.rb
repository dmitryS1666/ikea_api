class FilterValue < ApplicationRecord
  validates :value_id, presence: true, uniqueness: true
  
  belongs_to :filter
  has_many :product_filter_values
  has_many :products, through: :product_filter_values
end
