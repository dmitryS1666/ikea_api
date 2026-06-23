# frozen_string_literal: true

require "json"

class SeoCatalogPage < ApplicationRecord
  SEO_PATH_PREFIX = "/catalog/seo".freeze
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
  # В filter_config.filters и в filters_snapshot для фронта — только цена и коллекция.
  ALLOWED_FILTER_PARAMETERS = %w[f-series f-price-buckets].freeze
  FILTER_PARAMETER_ALIASES = {
    "series" => "f-series",
    "collection" => "f-series"
  }.freeze
  META_TITLE_MAX_LENGTH = 90
  META_DESCRIPTION_MAX_LENGTH = 220
  STATUS_LABELS = {
    "draft" => "Черновик",
    "published" => "Опубликовано",
    "archived" => "Архив"
  }.freeze

  enum status: { draft: 0, published: 1, archived: 2 }

  attr_writer :filter_config_json_input

  validates :slug, presence: true, uniqueness: true, format: {
    with: SLUG_FORMAT,
    message: "должен содержать только латинские буквы, цифры и дефисы"
  }
  validates :meta_title, length: { maximum: META_TITLE_MAX_LENGTH }, allow_blank: true
  validates :meta_description, length: { maximum: META_DESCRIPTION_MAX_LENGTH }, allow_blank: true
  validates :status, inclusion: { in: statuses.keys }
  validate :validate_filter_config
  validate :validate_published_payload

  before_validation :normalize_slug
  before_validation :apply_filter_config_json_input
  before_validation :normalize_snapshots
  before_validation :fill_canonical_path
  before_save :set_published_at

  after_commit :revalidate_frontend_page, if: :should_revalidate_frontend?

  scope :ordered, -> { order(position: :asc, updated_at: :desc) }
  scope :for_frontend, -> { published.ordered }
  scope :for_sitemap, -> { published.where(indexable: true).where("products_count > 0").ordered }

  def self.status_select_options
    statuses.keys.map { |key| [human_status(key), key] }
  end

  def self.human_status(value)
    STATUS_LABELS.fetch(value.to_s, value.to_s)
  end

  def self.normalize_filter_parameter(key)
    FILTER_PARAMETER_ALIASES.fetch(key.to_s, key.to_s)
  end

  def self.allowed_filter_parameter?(parameter)
    ALLOWED_FILTER_PARAMETERS.include?(parameter.to_s)
  end

  def path
    "#{SEO_PATH_PREFIX}/#{slug}"
  end

  def frontend_url
    base = ENV["FRONTEND_URL"].presence || ENV["FRONTEND_BASE_URL"].presence
    return path if base.blank?

    "#{base.to_s.chomp('/')}#{path}"
  end

  def filter_config_json_input
    return @filter_config_json_input if instance_variable_defined?(:@filter_config_json_input)

    JSON.pretty_generate(filter_config.presence || {})
  rescue JSON::GeneratorError
    filter_config.to_s
  end

  # Храним snapshot товаров в том же формате, который отдает ProductTeaserSerializer:
  # { "data" => [...], "meta" => {...} }.
  # Для старых snapshot, созданных до этой доработки, сохраняем обратную совместимость.
  def products_snapshot_for_api
    case products_snapshot
    when Hash
      products_snapshot
    when Array
      { "data" => products_snapshot, "meta" => { "total" => products_snapshot.size } }
    else
      { "data" => [], "meta" => { "total" => 0 } }
    end
  end

  def products_data_for_api
    Array.wrap(products_snapshot_for_api["data"] || products_snapshot_for_api[:data])
  end

  def filters_snapshot_for_api
    Array.wrap(filters_snapshot)
  end

  def frontend_list_payload
    {
      slug: slug,
      path: path,
      updated_at: updated_at&.iso8601,
      last_generated_at: last_generated_at&.iso8601,
      indexable: indexable,
      products_count: products_count
    }
  end

  def frontend_detail_payload
    available_filters = filters_snapshot_for_api

    {
      slug: slug,
      path: path,
      h1: h1,
      meta_title: meta_title,
      meta_description: meta_description,
      seo_text: seo_text,
      canonical_path: canonical_path.presence || path,
      indexable: indexable,
      filter_config: filter_config.presence || {},
      filters: available_filters,
      available_filters: available_filters,
      products: products_snapshot_for_api,
      products_count: products_count,
      last_generated_at: last_generated_at&.iso8601
    }
  end

  private

  def normalize_slug
    self.slug = slug.to_s.strip.downcase
  end

  def apply_filter_config_json_input
    return unless instance_variable_defined?(:@filter_config_json_input)

    text = @filter_config_json_input.to_s.strip
    self.filter_config = text.blank? ? {} : JSON.parse(text)
  rescue JSON::ParserError => e
    errors.add(:filter_config, "содержит невалидный JSON: #{e.message}")
  end

  def normalize_snapshots
    self.filter_config = {} if filter_config.nil?
    self.products_snapshot = [] if products_snapshot.nil?
    self.filters_snapshot = [] if has_attribute?(:filters_snapshot) && filters_snapshot.nil?
  end

  def fill_canonical_path
    self.canonical_path = path if canonical_path.blank? && slug.present?
  end

  def validate_filter_config
    unless filter_config.is_a?(Hash)
      errors.add(:filter_config, "должен быть JSON-объектом")
      return
    end

    validate_filter_config_filters
  end

  def validate_filter_config_filters
    raw = filter_config["filters"]
    return if raw.blank?

    unless raw.is_a?(Hash)
      errors.add(:filter_config, "filters должен быть объектом")
      return
    end

    raw.each_key do |key|
      normalized = self.class.normalize_filter_parameter(key)
      next if self.class.allowed_filter_parameter?(normalized)

      errors.add(
        :filter_config,
        "фильтр «#{key}» не поддерживается. Допустимы только коллекция (f-series) и цена (f-price-buckets); min_price/max_price задаются отдельно"
      )
    end
  end

  def validate_published_payload
    return unless published?

    errors.add(:h1, "обязателен для опубликованной страницы") if h1.blank?
    errors.add(:meta_title, "обязателен для опубликованной страницы") if meta_title.blank?
    errors.add(:meta_description, "обязателен для опубликованной страницы") if meta_description.blank?
    errors.add(:filter_config, "не может быть пустым для опубликованной страницы") if filter_config.blank?
  end

  def set_published_at
    if published?
      self.published_at ||= Time.current
    elsif will_save_change_to_status?
      self.published_at = nil
    end
  end

  def should_revalidate_frontend?
    return false unless published?
    return false if ENV["FRONTEND_REVALIDATE_URL"].blank?

    previous_changes.slice(
      "slug",
      "h1",
      "meta_title",
      "meta_description",
      "seo_text",
      "canonical_path",
      "indexable",
      "status",
      "products_snapshot",
      "filters_snapshot",
      "products_count",
      "last_generated_at"
    ).present?
  end

  def revalidate_frontend_page
    paths = [path]
    if previous_changes["slug"]&.first.present?
      paths << "#{SEO_PATH_PREFIX}/#{previous_changes['slug'].first}"
    end

    SeoCatalogPages::RevalidateFrontendService.call(paths: paths.uniq)
  rescue StandardError => e
    Rails.logger.warn("SeoCatalogPage revalidation failed id=#{id}: #{e.class}: #{e.message}")
  end
end
