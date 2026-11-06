# frozen_string_literal: true

# Дата последнего изменения публикуемых данных карточки.
# Ежедневная синхронизация цены и остатка не должна сдвигать её,
# если название, фото, цена, наличие и остальные поля витрины те же.
module ProductContentTimestamp
  extend ActiveSupport::Concern

  PUBLIC_CARD_COLUMNS = %w[
    name name_ru small_desc_name collection cached_slug
    content content_ru short_description short_description_ru
    material_info material_info_ru good_info good_info_ru
    materials materials_ru features features_ru
    care_instructions care_instructions_ru
    environmental_info environmental_info_ru
    safety_info safety_info_ru good_to_know good_to_know_ru
    designer designer_ru
    images local_images videos manuals assembly_documents
    price quantity price_addon_pln
    weight net_weight package_volume package_dimensions packaging
    dimensions dimensions_ru full_attributes
    category_id
    variants related_products set_items included_products variants_payload
    rating_avg rating_weighted rating_count
    is_parcel is_bestseller is_popular is_new is_recommended
    delivery_cost delivery_type delivery_name delivery_reason home_delivery
  ].freeze

  SERIALIZED_CARD_COLUMNS = %w[
    variants related_products set_items included_products
    images local_images videos manuals features assembly_documents
  ].freeze

  NUMERIC_CARD_COLUMNS = %w[
    price quantity price_addon_pln
    weight net_weight package_volume
    rating_avg rating_weighted rating_count
    delivery_cost
  ].freeze

  BOOLEAN_CARD_COLUMNS = %w[
    is_parcel is_bestseller is_popular is_new is_recommended
  ].freeze

  included do
    before_save :stamp_content_updated_at
  end

  def update_columns(attributes)
    attrs = attributes.stringify_keys
    if content_timestamp_column? && !attrs.key?("content_updated_at") && public_card_column_values_changed?(attrs)
      attrs["content_updated_at"] = Time.current
    end
    super(attrs)
  end

  def public_card_values_unchanged?(attrs)
    !public_card_column_values_changed?(attrs.stringify_keys)
  end

  private

  def stamp_content_updated_at
    return unless content_timestamp_column?

    if new_record?
      self.content_updated_at ||= Time.current
      return
    end

    return unless (changed.map(&:to_s) & PUBLIC_CARD_COLUMNS).any?

    self.content_updated_at = Time.current
  end

  def content_timestamp_column?
    has_attribute?(:content_updated_at)
  end

  def public_card_column_values_changed?(attrs)
    PUBLIC_CARD_COLUMNS.any? do |column|
      next false unless attrs.key?(column)

      !card_values_equal?(column, self[column], attrs[column])
    end
  end

  def card_values_equal?(column, current, incoming)
    current = unwrap_serialized_card_value(column, current)
    incoming = unwrap_serialized_card_value(column, incoming)

    if NUMERIC_CARD_COLUMNS.include?(column)
      return true if current.nil? && incoming.nil?
      return false if current.nil? || incoming.nil?

      return current.to_d == incoming.to_d
    end

    if BOOLEAN_CARD_COLUMNS.include?(column)
      caster = ActiveModel::Type::Boolean.new
      return caster.cast(current) == caster.cast(incoming)
    end

    if current.is_a?(Hash) || incoming.is_a?(Hash) || current.is_a?(Array) || incoming.is_a?(Array)
      return current.as_json == incoming.as_json
    end

    current == incoming
  end

  def unwrap_serialized_card_value(column, value)
    return value unless SERIALIZED_CARD_COLUMNS.include?(column)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value)
    parsed.is_a?(Array) || parsed.is_a?(Hash) ? parsed : value
  rescue JSON::ParserError
    value
  end
end
