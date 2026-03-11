class CategoryCatalogRowMapping < ApplicationRecord
  validates :row_no, presence: true, uniqueness: true

  belongs_to :category,
             class_name: 'Category',
             foreign_key: :ikea_id,
             primary_key: :ikea_id,
             optional: true
end
