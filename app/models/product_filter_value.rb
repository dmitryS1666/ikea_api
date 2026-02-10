class ProductFilterValue < ApplicationRecord
  belongs_to :product
  belongs_to :filter_value
end
