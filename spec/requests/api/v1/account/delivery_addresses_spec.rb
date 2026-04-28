require "rails_helper"

RSpec.describe "Account Delivery Addresses API", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:token) { JwtService.encode(user_id: user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  describe "GET /api/v1/account/delivery_addresses" do
    it "returns only current user addresses" do
      own_address = create(:user_delivery_address, user: user)
      create(:user_delivery_address, user: other_user)

      get "/api/v1/account/delivery_addresses", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      ids = body.fetch("data").map { |row| row["id"].to_i }
      expect(ids).to contain_exactly(own_address.id)
    end
  end

  describe "POST /api/v1/account/delivery_addresses" do
    it "creates address and returns formatted_address" do
      post "/api/v1/account/delivery_addresses", params: {
        city: "Минск",
        street: "Притыцкого",
        house: "1",
        building: "2",
        apartment: "10"
      }, headers: headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      attrs = body.dig("data", "attributes")
      expect(attrs["formatted_address"]).to include("Минск")
      expect(user.user_delivery_addresses.alive.count).to eq(1)
    end

    it "clears apartment fields for private house" do
      post "/api/v1/account/delivery_addresses", params: {
        city: "Минск",
        street: "Притыцкого",
        house: "1",
        apartment: "10",
        entrance: "2",
        floor: "5",
        has_elevator: true,
        intercom: "123",
        is_private_house: true
      }, headers: headers

      expect(response).to have_http_status(:created)
      address = user.user_delivery_addresses.alive.last
      expect(address.apartment).to be_nil
      expect(address.entrance).to be_nil
      expect(address.floor).to be_nil
      expect(address.has_elevator).to be_nil
      expect(address.intercom).to be_nil
    end
  end

  describe "PATCH /api/v1/account/delivery_addresses/:id" do
    it "updates own address" do
      address = create(:user_delivery_address, user: user, street: "Старая улица")

      patch "/api/v1/account/delivery_addresses/#{address.id}", params: { street: "Новая улица" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(address.reload.street).to eq("Новая улица")
    end

    it "does not update other user address" do
      address = create(:user_delivery_address, user: other_user, street: "Старая улица")

      patch "/api/v1/account/delivery_addresses/#{address.id}", params: { street: "Новая улица" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(address.reload.street).to eq("Старая улица")
    end
  end

  describe "DELETE /api/v1/account/delivery_addresses/:id" do
    it "soft deletes own address" do
      address = create(:user_delivery_address, user: user)

      delete "/api/v1/account/delivery_addresses/#{address.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(address.reload.deleted_at).to be_present
    end

    it "does not delete other user address" do
      address = create(:user_delivery_address, user: other_user)

      delete "/api/v1/account/delivery_addresses/#{address.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(address.reload.deleted_at).to be_nil
    end
  end
end
