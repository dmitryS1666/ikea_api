class Filter < ApplicationRecord
  validates :parameter, presence: true, uniqueness: true
  
  has_many :filter_values
end
