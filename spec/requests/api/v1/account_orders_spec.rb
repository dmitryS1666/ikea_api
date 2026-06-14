require "rails_helper"

RSpec.describe "Account orders list", type: :request do
  let(:user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  def fetch_order_ids
    get "/api/v1/account/orders", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)["data"].map { |row| row["id"] }
  end

  it "excludes cancelled checkout drafts from the list" do
    visible = create(:order, user: user, status: :processing, checkout_draft: false)
    create(:order, user: user, status: :cancelled, checkout_draft: true)

    ids = fetch_order_ids
    expect(ids).to include(visible.public_uid)
    expect(user.orders.where(checkout_draft: true, status: :cancelled).count).to eq(1)
  end

  it "excludes stale unfinalized checkout drafts from the list" do
    visible = create(:order, user: user, status: :processing, checkout_draft: false)
    stale = create(:order, user: user, status: :created, checkout_draft: true)
    stale.update_column(:created_at, 25.hours.ago)

    ids = fetch_order_ids
    expect(ids).to include(visible.public_uid)
    expect(ids).not_to include(stale.public_uid)
  end

  it "includes recent checkout drafts and finalized orders in any status" do
    recent_draft = create(:order, user: user, status: :created, checkout_draft: true)
    finalized = create(:order, user: user, status: :cancelled, checkout_draft: false)

    ids = fetch_order_ids
    expect(ids).to include(recent_draft.public_uid, finalized.public_uid)
  end
end
