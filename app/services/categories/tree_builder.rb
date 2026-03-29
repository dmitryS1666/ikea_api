# frozen_string_literal: true

require "set"

module Categories
  class TreeBuilder
    def initialize(scope = Category.all)
      @scope = scope
      @url_helpers = Rails.application.routes.url_helpers
    end

    def call
      categories = @scope.order(:top_position, :id).to_a

      children_map = Hash.new { |hash, key| hash[key] = [] }
      roots = []

      categories.each do |category|
        pid = parent_id(category)

        if pid.present? && pid != category.ikea_id
          children_map[pid] << category
        else
          roots << category
        end
      end

      {
        data: sort_alphabetically(roots).filter_map do |category|
          serialize_node(category, children_map, 1, Set.new)
        end
      }
    end

    private

    def serialize_node(category, children_map, depth, visited)
      category_id = category.ikea_id
      return nil if category_id.blank?
      return nil if visited.include?(category_id)

      visited.add(category_id)

      children = children_map[category_id]
      children = sort_alphabetically(children) if depth == 1

      {
        id: category_id,
        type: "category",
        attributes: {
          translated_name: category.translated_name,
          slug: category.slug,
          icon_url: depth == 2 ? blob_path(category.icon) : nil,
          pictogram_url: depth == 1 ? blob_path(category.pictogram) : nil
        },
        children: children.filter_map do |child|
          serialize_node(child, children_map, depth + 1, visited)
        end
      }
    ensure
      visited.delete(category_id) if category_id.present?
    end

    def sort_alphabetically(categories)
      categories.sort_by do |category|
        category.translated_name.to_s.mb_chars.downcase.to_s
      end
    end

    def parent_id(category)
      ids = category.parent_ids || []
      return nil if ids.empty?

      ids.last == category.ikea_id ? ids[-2] : ids.last
    end

    def blob_path(attachment)
      return nil unless attachment.attached?

      @url_helpers.rails_blob_url(attachment, only_path: true)
    rescue StandardError
      nil
    end
  end
end
