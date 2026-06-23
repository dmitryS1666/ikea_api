# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/webhooks/amo_crm", type: :request do
  let!(:order) do
    create(
      :order,
      crm_external_id: "999888",
      status: :processing,
      track_number: nil,
      weight: 1.0,
      cancellation_reason: nil
    )
  end

  def post_lead_update(lead_payload, as_json: false)
    params = {
      "leads" => {
        "update" => {
          "0" => lead_payload
        }
      }
    }

    if as_json
      post "/api/v1/webhooks/amo_crm", params: params, as: :json
    else
      post "/api/v1/webhooks/amo_crm", params: params
    end
  end

  it "updates order status from AmoCRM lead webhook" do
    post_lead_update(
      {
        "id" => order.crm_external_id,
        "status_id" => Order.statuses[:paid],
        "updated_at" => Time.current.to_i
      }
    )

    expect(response).to have_http_status(:ok)
    expect(order.reload.status).to eq("paid")
    expect(order.order_status_events.last.source).to eq("amo_webhook")
  end

  it "merges track number, weight and cancellation reason from custom fields" do
    post_lead_update(
      {
        "id" => order.crm_external_id,
        "status_id" => order.status_before_type_cast,
        "custom_fields_values" => [
          { "field_id" => 377_661, "values" => [{ "value" => "BY123456789" }] },
          { "field_id" => 363_323, "values" => [{ "value" => "12.5" }] },
          { "field_id" => 578_819, "values" => [{ "value" => "Клиент передумал" }] }
        ]
      },
      as_json: true
    )

    expect(response).to have_http_status(:ok)
    order.reload
    expect(order.track_number).to eq("BY123456789")
    expect(order.weight).to eq(12.5)
    expect(order.cancellation_reason).to eq("Клиент передумал")
  end

  it "ignores unmapped AmoCRM status ids" do
    post_lead_update(
      {
        "id" => order.crm_external_id,
        "status_id" => 1,
        "updated_at" => Time.current.to_i
      }
    )

    expect(response).to have_http_status(:ok)
    expect(order.reload.status).to eq("processing")
  end

  it "ignores leads without a matching local order" do
    post_lead_update(
      {
        "id" => "000001",
        "status_id" => Order.statuses[:completed]
      }
    )

    expect(response).to have_http_status(:ok)
    expect(order.reload.status).to eq("processing")
  end
end
