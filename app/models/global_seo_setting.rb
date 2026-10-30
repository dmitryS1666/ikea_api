class GlobalSeoSetting < ApplicationRecord
  validates :target_type, presence: true, uniqueness: true

  # target_type: 'home', 'catalog', 'category', 'product', 'article', 'static_page'

  after_commit :bust_cached_category_payloads

  def self.for(type)
    find_by(target_type: type)
  end

  private

  def bust_cached_category_payloads
    Categories::ShowCache.bust_all!
  end
end
