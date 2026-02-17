class SeoMetum < ApplicationRecord
  belongs_to :seoable, polymorphic: true

  validates :title, length: { maximum: 255 }, allow_blank: true
  validates :description, length: { maximum: 500 }, allow_blank: true
end
