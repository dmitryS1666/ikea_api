# frozen_string_literal: true

require "set"

module Categories
  class TreeBuilder
    def initialize(scope = Category.all, city_code: nil)
      @scope = scope
      @url_helpers = Rails.application.routes.url_helpers
    end

    def call
      categories =
        if @scope.is_a?(ActiveRecord::Relation)
          @scope
            .except(:order)
            .with_attached_icon
            .with_attached_pictogram
            .to_a
        else
          Array(@scope)
        end

      children_map = Hash.new { |hash, key| hash[key] = [] }
      roots = []

      categories.each do |category|
        pid = parent_id(category)

        if pid.present? && pid != category.ikea_id.to_s
          children_map[pid] << category
        else
          roots << category
        end
      end

      {
        data: sort_root_categories(roots).filter_map do |category|
          serialize_node(category, children_map, 1, Set.new)
        end
      }
    end

    private

    def serialize_node(category, children_map, depth, visited)
      category_id = category.ikea_id.to_s
      return nil if category_id.blank?
      return nil if visited.include?(category_id)

      visited.add(category_id)

      children = children_map[category_id]
      children = sort_child_categories(children) if depth == 1

      {
        id: category_id,
        attributes: {
          translated_name: category.translated_name,
          slug: category.slug,
          root_position: safe_root_position(category),
          icon_url: depth == 1 || depth == 2 ? blob_path(category.icon) : nil,
          pictogram_url: depth == 1 ? blob_path(category.pictogram) : nil
        },
        children: children.filter_map do |child|
          serialize_node(child, children_map, depth + 1, visited)
        end
      }
    ensure
      visited.delete(category_id) if category_id.present?
    end

    def sort_root_categories(categories)
      categories.sort_by do |category|
        [
          safe_root_position(category),
          normalized_name(category)
        ]
      end
    end

    def sort_child_categories(categories)
      categories.sort_by do |category|
        normalized_name(category)
      end
    end

    def normalized_name(category)
      (category.translated_name.presence || category.name).to_s.mb_chars.downcase.to_s
    end

    def safe_root_position(category)
      return 0 unless category.has_attribute?(:root_position)

      category[:root_position].to_i
    rescue ActiveModel::MissingAttributeError
      0
    end

    def parent_id(category)
      ids = Category.normalize_parent_ids(category.parent_ids)
      return nil if ids.empty?

      ids.last == category.ikea_id.to_s ? ids[-2].to_s : ids.last.to_s
    end

    def blob_path(attachment)
      return nil unless attachment.attached?

      @url_helpers.rails_blob_url(attachment, only_path: true)
    rescue StandardError
      nil
    end
  end
end
