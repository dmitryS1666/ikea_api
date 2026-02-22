require 'swagger_helper'

RSpec.describe 'Categories API (public)', type: :request do
  path '/api/v1/categories' do
    get 'List categories' do
      tags 'Categories'
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 50)'

      response '200', 'successful' do
        schema type: :object,
               properties: {
                 data: {
                   type: :array,
                   items: { '$ref' => '#/components/schemas/category' }
                 },
                 meta: {
                   type: :object,
                   properties: {
                     total: { type: :integer },
                     page: { type: :integer },
                     per_page: { type: :integer },
                     total_pages: { type: :integer }
                   }
                 }
               }
        run_test!
      end
    end
  end

  path '/api/v1/categories/{id}' do
    get 'Show category' do
      tags 'Categories'
      produces 'application/json'
      parameter name: :id, in: :path, type: :integer, required: true

      response '404', 'not found' do
        let(:id) { 999_999 }
        run_test!
      end
    end
  end

  path '/api/v1/categories/{id}/products' do
    get 'List products for category' do
      tags 'Categories'
      produces 'application/json'
      description <<~DESC
        Returns a paginated list of products belonging to the specified category by its IKEA ID.

        Filtering:
        - Use available filter values from category.available_filters (see Category payload)
        - Send selected filters as query params: filters[PARAMETER][]=VALUE_ID (VALUE_ID comes from available_filters.values[].id)

        Example:
        /api/v1/categories/700403/products?filters[f-type][]=50310&filters[f-price-buckets][]=PRICE_19900_19901
      DESC
      parameter name: :id, in: :path, type: :string, required: true, description: 'IKEA ID of the category (e.g. 10001)'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 50)'
      parameter name: :filters, in: :query, required: false, description: 'Filter map: filters[f-type][]=50310&filters[f-price-buckets][]=PRICE_19900_19901'

      response '200', 'successful' do
        schema type: :object,
               properties: {
                 data: {
                   type: :array,
                   items: { '$ref' => '#/components/schemas/product' }
                 },
                meta: {
                   type: :object,
                   properties: {
                     total: { type: :integer },
                     page: { type: :integer },
                    per_page: { type: :integer },
                    total_pages: { type: :integer },
                    default_sort: { type: :string },
                    available_filters: { type: :array }
                   }
                 }
               }
        let(:category) { create(:category) }
        let(:id) { category.ikea_id }
        run_test!
      end

      response '404', 'category not found' do
        schema type: :object,
               properties: {
                 error: { type: :string }
               }
        let(:id) { 'non-existent' }
        run_test!
      end
    end
  end

  path '/api/v1/categories/tree' do
    get 'Categories tree' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/categories/map' do
    get 'Categories map' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/categories/popular' do
    get 'Popular categories' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
