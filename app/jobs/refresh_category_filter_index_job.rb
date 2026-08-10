# frozen_string_literal: true

# Rebuilds the complete storefront filter index for one category.
#
# IKEA facets (color, material, type, etc.) must come from IKEA's filtered
# search response. Local facets (price, series and other calculated values)
# are rebuilt from the local product data afterwards.
class RefreshCategoryFilterIndexJob < ApplicationJob
  queue_as :parser

  def perform(category_id)
    category = Category.find_by(ikea_id: category_id.to_s)
    unless category
      Rails.logger.error("RefreshCategoryFilterIndexJob: category not found: #{category_id}")
      return
    end

    facet_result = Categories::IkeaFacetMembershipSyncService.new(category).call
    Products::FilterValuesIndexer.new(category.reload).reindex!
    Categories::ShowCache.bust!(category.ikea_id)

    errors = Array(facet_result.errors)
    return facet_result if errors.empty?

    details = errors.map do |error|
      data = error.to_h.with_indifferent_access
      "#{data[:parameter]}=#{data[:value_id]}: #{data[:message]}"
    end.join("; ")

    raise "Category #{category.ikea_id} filter index was only partially refreshed: #{details}"
  end
end
