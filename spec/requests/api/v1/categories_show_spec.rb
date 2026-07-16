# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Categories#show", type: :request do
  let!(:category) { create(:category, ikea_id: "700403", name: "Storage", translated_name: "Хранение") }

  around do |example|
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = previous_cache
  end

  before do
    allow(ExchangeRate).to receive(:fetch_or_create).with("PLN").and_return(
      instance_double(ExchangeRate, rate_per_unit: 0.3)
    )
    allow(CalculatorSetting).to receive(:get).with("exchange_rate_buffer").and_return(1.05)
  end

  it "returns category payload" do
    get "/api/v1/categories/#{category.ikea_id}"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "id")).to eq(category.ikea_id)
    expect(body.dig("data", "attributes", "translated_name")).to eq("Хранение")
  end

  it "returns 404 for unknown category" do
    get "/api/v1/categories/missing-category"

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)).to eq("error" => "Category not found")
  end

  it "reuses cached payload on repeated requests" do
    expect(CategorySerializer).to receive(:new).once.and_call_original

    get "/api/v1/categories/#{category.ikea_id}"
    expect(response).to have_http_status(:ok)

    get "/api/v1/categories/#{category.ikea_id}"
    expect(response).to have_http_status(:ok)
  end
end
