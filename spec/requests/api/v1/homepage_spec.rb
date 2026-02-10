require 'swagger_helper'

RSpec.describe 'Homepage API (public)', type: :request do
  path '/api/v1/homepage/slider/main' do
    get 'Main homepage slider' do
      tags 'Homepage'
      produces 'application/json'

      response '200', 'successful' do
        run_test!
      end

      response '404', 'not found' do
        run_test!
      end
    end
  end
end
