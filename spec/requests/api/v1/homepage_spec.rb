require 'swagger_helper'

RSpec.describe 'Homepage API (public)', type: :request do
  path '/api/v1/homepage/slider/main' do
    get 'Main homepage slider' do
      tags 'Homepage'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/homepage/slider/horizontal' do
    get 'Horizontal homepage banner' do
      tags 'Homepage'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/homepage/slider/advertising' do
    get 'Advertising homepage banners' do
      tags 'Homepage'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end

  path '/api/v1/homepage/slider/banners' do
    get 'Legacy alias for horizontal banners' do
      tags 'Homepage'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
