class GlobalSeoSetting < ApplicationRecord
  validates :target_type, presence: true, uniqueness: true

  # target_type: 'home', 'category', 'product', 'article', 'static_page'
  
  def self.for(type)
    find_by(target_type: type)
  end
end
