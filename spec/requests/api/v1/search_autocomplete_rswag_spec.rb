# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Search autocomplete API", type: :request do
  path "/api/v1/search/autocomplete" do
    get "Search autocomplete" do
      tags "Search"
      produces "application/json"
      parameter name: :q,
                in: :query,
                type: :string,
                required: true,
                description: "Строка поиска для dropdown; до 2 символов возвращаются пустые массивы"

      response "200", "autocomplete suggestions" do
        let(:q) { "шкафы" }

        schema type: :object,
               properties: {
                 query: { type: :string },
                 normalized_query: { type: :string },
                 suggestions: {
                   type: :array,
                   items: {
                     type: :object,
                     properties: {
                       title: { type: :string },
                       query: { type: :string }
                     }
                   }
                 },
                 categories: {
                   type: :array,
                   items: {
                     type: :object,
                     properties: {
                       id: { type: :string },
                       title: { type: :string },
                       slug: { type: :string },
                       url: { type: :string },
                       local_image_path: { type: :string, nullable: true }
                     }
                   }
                 },
                 products: {
                   type: :array,
                   items: {
                     type: :object,
                     properties: {
                       sku: { type: :string },
                       slug: { type: :string },
                       url: { type: :string },
                       name_ru: { type: :string },
                       small_desc_name: { type: :string, nullable: true },
                       title: { type: :string },
                       category_title: { type: :string, nullable: true },
                       category_url: { type: :string, nullable: true },
                       preview_image: { type: :string, nullable: true }
                     }
                   }
                 }
               },
               required: %w[query normalized_query suggestions categories products]

        run_test!
      end
    end
  end
end
