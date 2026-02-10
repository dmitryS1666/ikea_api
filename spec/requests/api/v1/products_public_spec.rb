require 'swagger_helper'

RSpec.describe 'Products API (public)', type: :request do
  path '/api/v1/products' do
    get 'List products' do
      tags 'Products'
      produces 'application/json'

      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false
      parameter name: :sort, in: :query, type: :string, required: false, description: 'rating|newest|oldest|price_asc|price_desc'
      parameter name: :category_id, in: :query, type: :integer, required: false
      parameter name: :in_stock, in: :query, type: :boolean, required: false

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/products/{sku}' do
    get 'Show product (by sku)' do
      tags 'Products'
      produces 'application/json'
      parameter name: :sku, in: :path, type: :string, required: true

      response '404', 'not found' do
        let(:sku) { 'NON_EXISTING_SKU' }
        run_test!
      end
    end
  end

  path '/api/v1/products/bestsellers' do
    get 'Bestsellers' do
      tags 'Products'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/products/popular' do
    get 'Popular products' do
      tags 'Products'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
