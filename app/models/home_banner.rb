class HomeBanner < ApplicationRecord
  require 'mini_magick'

  SECTION_VARIANTS = {
    'main' => {
      'desktop' => 'main_1500x516',
      'tablet' => 'main_960x516',
      'mobile' => 'main_572x594'
    },
    'horizontal' => {
      'desktop' => 'horizontal_1500x256',
      'tablet' => 'horizontal_960x256',
      'mobile' => 'horizontal_742x256'
    },
    'advertising' => {
      'desktop' => 'advertising_742x256',
      'tablet' => 'advertising_960x256',
      'mobile' => 'advertising_mobile_960x256'
    }
  }.freeze

  VARIANT_DIMENSIONS = {
    'main_1500x516' => [1500, 516],
    'main_960x516' => [960, 516],
    'main_572x594' => [572, 594],
    'horizontal_1500x256' => [1500, 256],
    'horizontal_960x256' => [960, 256],
    'horizontal_742x256' => [742, 256],
    'advertising_742x256' => [742, 256],
    'advertising_960x256' => [960, 256],
    'advertising_mobile_960x256' => [960, 256],
    # legacy (removed from admin; kept so old rows still load)
    'advertising_1500x256' => [1500, 256]
  }.freeze

  VARIANT_BREAKPOINTS = {
    'main_1500x516' => 'desktop',
    'main_960x516' => 'tablet',
    'main_572x594' => 'mobile',
    'horizontal_1500x256' => 'desktop',
    'horizontal_960x256' => 'tablet',
    'horizontal_742x256' => 'mobile',
    'advertising_742x256' => 'desktop',
    'advertising_960x256' => 'tablet',
    'advertising_mobile_960x256' => 'mobile',
    'advertising_1500x256' => 'desktop'
  }.freeze

  # Enums — integer values kept for backward compatibility with existing rows.
  # section 1 was historically "secondary"; variant 2/3/5 were "secondary_*".
  enum section: {
    main: 0,
    horizontal: 1,
    advertising: 2
  }

  enum variant: {
    main_1500x516: 0,
    main_572x594: 1,
    horizontal_1500x256: 2,
    horizontal_742x256: 3,
    main_960x516: 4,
    horizontal_960x256: 5,
    advertising_742x256: 6,
    advertising_1500x256: 7,
    advertising_960x256: 8,
    advertising_mobile_960x256: 9
  }

  enum breakpoint: {
    desktop: 0,
    tablet: 1,
    mobile: 2,
    all: 3
  }, _prefix: true

  # Associations
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true
  has_one_attached :image

  has_one :seo_meta, as: :seoable, class_name: 'SeoMetum', dependent: :destroy

  # Callbacks
  before_validation :normalize_category_id
  before_validation :normalize_slot_key
  before_validation :sync_breakpoint_from_variant
  before_validation :ensure_slot_key
  before_validation :sync_slot_position
  before_validation :optimize_uploaded_image
  after_commit :invalidate_homepage_banner_cache

  # Validations
  validates :section, presence: true
  validates :variant, presence: true
  validates :breakpoint, presence: true
  validates :slot_key, presence: true
  validates :position, presence: true, numericality: { only_integer: true }
  validate :validate_image_presence
  validate :validate_image_content_type
  validate :validate_variant_matches_section
  validate :validate_link_presence
  validate :validate_unique_active_slot_breakpoint

  # Scopes
  scope :by_position, -> { order(position: :asc, breakpoint: :asc, id: :asc) }
  scope :active, -> { where(active: true) }
  # Legacy alias used by older callers/docs ("secondary" == horizontal)
  scope :secondary, -> { where(section: :horizontal) }

  # Instance methods
  def image_url
    return nil unless image.attached?

    Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true)
  end

  def expected_dimensions
    VARIANT_DIMENSIONS[variant]
  end

  def final_link
    return custom_url if custom_url.present?
    return "/categories/#{category.ikea_id}" if category.present?

    nil
  end

  def self.variants_for_section(section_name)
    SECTION_VARIANTS[section_name.to_s] || {}
  end

  private

  def validate_image_presence
    errors.add(:image, 'must be present') unless image.attached?
  end

  def validate_image_content_type
    return unless image.attached?

    allowed_types = %w[image/webp image/avif image/png image/jpeg]
    content_type = image.content_type

    unless allowed_types.include?(content_type)
      errors.add(:image, 'must be a WebP, AVIF, PNG, or JPEG image')
    end
  end

  def validate_variant_matches_section
    return unless section.present? && variant.present?

    allowed = SECTION_VARIANTS.fetch(section, {}).values
    return if allowed.include?(variant)

    errors.add(:variant, "does not match section #{section}")
  end

  def validate_link_presence
    return if custom_url.present? || category_id.present?

    errors.add(:base, 'Укажите категорию или кастомную ссылку')
  end

  def validate_unique_active_slot_breakpoint
    return unless active?
    return if section.blank? || slot_key.blank? || breakpoint.blank?

    scope = HomeBanner.active
                      .where(section: section, slot_key: slot_key, breakpoint: breakpoint)
    scope = scope.where.not(id: id) if persisted?

    return unless scope.exists?

    errors.add(:breakpoint, 'уже есть активная запись для этого slot_key')
  end

  def normalize_category_id
    self.category_id = nil if category_id.blank?
  end

  def normalize_slot_key
    self.slot_key = slot_key.to_s.strip.presence
  end

  def sync_breakpoint_from_variant
    mapped = VARIANT_BREAKPOINTS[variant]
    self.breakpoint = mapped if mapped.present?
  end

  def ensure_slot_key
    return if slot_key.present?

    prefix = section.presence || 'banner'
    pos = position.presence || 0
    self.slot_key = "#{prefix}-#{pos}"
  end

  def sync_slot_position
    return if slot_key.blank? || section.blank?
    # Do not overwrite an explicit position change on update — otherwise the admin
    # value is immediately reset to the sibling's old position.
    return if persisted? && will_save_change_to_position?

    sibling = HomeBanner.where(section: section, slot_key: slot_key)
                        .where.not(id: id || 0)
                        .order(:id)
                        .first
    self.position = sibling.position if sibling
  end

  def optimize_uploaded_image
    change = attachment_changes['image']
    return unless change.respond_to?(:attachable)

    blob = Images::WebpOptimizer.optimize_attachable_as_blob(change.attachable)
    image.attach(blob) if blob
  end

  def invalidate_homepage_banner_cache
    HomeBanner.bump_cache_version!
  end

  class << self
    def cache_version
      Rails.cache.read(cache_version_key).to_i
    end

    def bump_cache_version!
      Rails.cache.write(cache_version_key, Time.current.to_i)
    rescue StandardError => e
      Rails.logger.warn("HomeBanner.bump_cache_version! failed: #{e.class} #{e.message}")
    end

    def cache_version_key
      'homepage/banners/cache_version'
    end
  end
end
