# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::IkeaParcelFlagBackfill do
  let(:category) { create(:category) }

  def availability_response(item_no, parcel)
    {
      "availabilities" => [
        {
          "itemKey" => { "itemNo" => item_no },
          "buyingOption" => { "homeDelivery" => { "availability" => { "parcel" => parcel } } }
        }
      ]
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("IKEA_CLIENT_ID").and_return("test-client")
    allow(ProxyRotator).to receive(:with_proxy_retry).and_yield({})
    allow(PriceCalculationService).to receive(:for_product).and_return(card_price_byn: BigDecimal("1"))
  end

  it "stores parcel true and recalculates delivery to free GLS" do
    product = create(
      :product,
      category: category,
      sku: "30535109",
      item_no: "30535109",
      is_parcel: nil,
      delivery_cost: 69,
      delivery_type: "ikea_transport"
    )
    response = instance_double(HTTParty::Response, code: 200, parsed_response: availability_response("30535109", true))
    allow(IkeaApiService).to receive(:get).and_return(response)
    allow(IkeaDeliveryService).to receive(:quote).and_return(
      delivery_type: "gls_point",
      delivery_name: "GLS",
      delivery_reason: "parcel",
      cost_pln: BigDecimal("0")
    )

    result = described_class.call(skus: ["30535109"])

    product.reload
    expect(product.is_parcel).to be true
    expect(product.delivery_cost).to eq(0)
    expect(product.delivery_type).to eq("gls_point")
    expect(result[:stats][:parcel_true]).to eq(1)
    expect(result[:samples_before].first[:is_parcel]).to be_nil
    expect(result[:samples_after].first[:is_parcel]).to be true
  end

  it "stores parcel false instead of leaving the flag empty" do
    product = create(
      :product,
      category: category,
      sku: "11111111",
      item_no: "11111111",
      is_parcel: nil,
      delivery_cost: 19.99
    )
    response = instance_double(HTTParty::Response, code: 200, parsed_response: availability_response("11111111", false))
    allow(IkeaApiService).to receive(:get).and_return(response)
    allow(IkeaDeliveryService).to receive(:quote).and_return(
      delivery_type: "ikea_transport",
      delivery_name: "transport",
      delivery_reason: "cargo",
      cost_pln: BigDecimal("69")
    )

    described_class.call(skus: ["11111111"])

    expect(product.reload.is_parcel).to be false
    expect(product.delivery_cost).to eq(69)
  end
end
