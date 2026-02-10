module Api
  module V1
    class FiltersController < ApplicationController
      # Returns available filters and values.
      # Optional: category_id to limit counts to a category.
      def index
        scope = Product.all
        if params[:category_id].present?
          scope = scope.where(category_id: params[:category_id])
        end

        # Count products per filter value in one query
        counts = ProductFilterValue.joins(:product)
                                   .where(products: { id: scope.select(:id) })
                                   .group(:filter_value_id)
                                   .count

        filters = Filter.includes(:filter_values).order(:parameter).map do |filter|
          {
            id: filter.id,
            parameter: filter.parameter,
            name: filter.name,
            values: filter.filter_values.order(:value).map do |fv|
              {
                id: fv.id,
                value_id: fv.value_id,
                value: fv.value,
                count: counts[fv.id] || 0
              }
            end
          }
        end

        render json: { filters: filters }
      end
    end
  end
end
