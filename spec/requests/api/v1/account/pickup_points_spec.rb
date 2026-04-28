require "rails_helper"

RSpec.describe "Account Pickup Points API", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  describe "GET /api/v1/account/pickup_points" do
    it "returns only current user points" do
      own = create(:user_pickup_point, user: user)
      create(:user_pickup_point, user: other_user)

      get "/api/v1/account/pickup_points", headers: headers

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).fetch("data").map { |row| row["id"].to_i }
      expect(ids).to contain_exactly(own.id)
    end
  end

  describe "POST /api/v1/account/pickup_points" do
    let(:payload) do
      {
        provider: "europost",
        external_id: "12345",
        city: "Минск",
        address: "пр-т Пушкина, д. 28",
        working_hours: "Пн-Вс 10:00-21:00",
        lat: 53.9123,
        lng: 27.4567,
        raw_payload: {}
      }
    end

    it "creates pickup point entry" do
      post "/api/v1/account/pickup_points", params: payload, headers: headers

      expect(response).to have_http_status(:created)
      expect(user.user_pickup_points.alive.count).to eq(1)
    end

    it "does not create duplicate for same provider and external_id" do
      create(:user_pickup_point, user: user, provider: "europost", external_id: "12345", city: "Гомель")

      post "/api/v1/account/pickup_points", params: payload.merge(city: "Минск"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.user_pickup_points.alive.count).to eq(1)
      expect(user.user_pickup_points.alive.first.city).to eq("Минск")
    end

    it "rejects unsupported provider" do
      post "/api/v1/account/pickup_points", params: payload.merge(provider: "ikea"), headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["errors"].join).to match(/Provider/i)
    end
  end

  describe "DELETE /api/v1/account/pickup_points/:id" do
    it "soft deletes own point" do
      point = create(:user_pickup_point, user: user)

      delete "/api/v1/account/pickup_points/#{point.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(point.reload.deleted_at).to be_present
    end

    it "does not delete other user point" do
      point = create(:user_pickup_point, user: other_user)

      delete "/api/v1/account/pickup_points/#{point.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(point.reload.deleted_at).to be_nil
    end
  end
end
