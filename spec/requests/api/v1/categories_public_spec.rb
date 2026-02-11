require 'swagger_helper'

RSpec.describe 'Categories API (public)', type: :request do
  path '/api/v1/categories' do
    get 'List categories' do
      tags 'Categories'
      produces 'application/json'

      response '200', 'successful' do
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
      description 'Returns a paginated list of products belonging to the specified category by its IKEA ID'
      parameter name: :id, in: :path, type: :string, required: true, description: 'IKEA ID of the category (e.g. 10001)'
      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 50)'

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
                     per_page: { type: :integer }
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
