require "rails_helper"

RSpec.describe PolandTracks::Payload, "legacy recipient storage" do
  let(:passport) do
    { "passport_number" => "MP1234567", "issue_date" => "2015-01-01",
      "issued_by" => "РОВД", "identification_number" => "1234567A123AB1",
      "region" => "Минская", "city" => "Минск", "street" => "Ленина",
      "house" => "1", "building" => "2", "apartment" => "10", "postcode" => "220000" }
  end
  let(:user) do
    build(:user, first_name: "Иван", last_name: "Иванов", dob: Date.new(1990, 1, 1),
                 country_code: "RB", region: nil, city: nil, street: nil, house: nil,
                 building: nil, apartment: nil, postcode: nil,
                 encrypted_passport_json: passport.to_json)
  end
  let(:order) do
    build(:order, user: user, public_uid: "52314357", delivery_type: "ikeya_delivery",
                  address_json: { "delivery" => { "address" => {
                    "city" => "Гомель", "street" => "Советская", "house" => "99" } } })
  end
  let(:item) do
    build(:order_item, name_snapshot: "Стеллаж", quantity: 1, poland_price_pln: 99.99,
                       poland_product_url: "https://www.ikea.com/pl/pl/p/example-123/")
  end
  before do
    allow(order).to receive(:order_items).and_return(double(order: [item]))
  end

  it "validates the legacy passport and keeps registration separate from delivery" do
    payload = described_class.snapshot(order)
    expect(described_class.validate!(payload)).to eq(true)
    expect(payload["recipient"]).to include(
      "passport_date" => "01.01.2015", "iin" => "1234567A123AB1",
      "region" => "Минская", "city" => "Минск", "street" => "Ленина",
      "building" => "1", "corpus" => "2", "apartment" => "10", "index" => "220000")
    expect(payload["delivery_address"]).to include("Гомель", "Советская", "99")
    expect(user.region).to be_nil
    expect(user.passport_data).to eq(passport)
  end

  it "keeps profile registration precedence including empty optional fields" do
    user.assign_attributes(region: "Брестская", city: "Брест", street: "Мира", house: "3", postcode: "224000")
    payload = described_class.snapshot(order)
    expect(described_class.validate!(payload)).to eq(true)
    expect(payload["recipient"]).to include("city" => "Брест", "building" => "3", "corpus" => nil, "apartment" => nil)
  end

  it "does not silently complete a partial profile with another address" do
    user.city = "Брест"
    payload = described_class.snapshot(order)
    expect(payload["recipient"]["street"]).to be_nil
    expect { described_class.validate!(payload) }.to raise_error(described_class::Invalid, /recipient.street/)
  end

  it "preserves existing passport field precedence" do
    user.encrypted_passport_json = passport.merge("issued_at" => "2016-02-03", "id_number" => "original-id").to_json
    expect(described_class.snapshot(order)["recipient"]).to include("passport_date" => "03.02.2016", "iin" => "original-id")
  end

  it "rejects an invalid legacy date" do
    user.encrypted_passport_json = passport.merge("issue_date" => "2015-02-30").to_json
    expect { described_class.validate!(described_class.snapshot(order)) }.to raise_error(described_class::Invalid, /passport_date/)
  end

  [nil, "", "   "].each do |empty_email|
    it "omits blank email #{empty_email.inspect} without substituting another address" do
      user.email = empty_email
      payload = described_class.snapshot(order)
      expect(payload["recipient"]).not_to have_key("email")
      expect(described_class.validate!(payload)).to eq(true)
    end
  end

  it "still rejects a supplied malformed email" do
    user.email = "invalid-email"
    expect { described_class.validate!(described_class.snapshot(order)) }.to raise_error(described_class::Invalid, /recipient.email/)
  end

  it "still blocks missing PLN when the catalog has no usable price or URL" do
    item.poland_price_pln = nil
    item.poland_product_url = nil
    allow(item).to receive(:ensure_poland_snapshot!).and_return(false)
    expect { described_class.validate!(described_class.snapshot(order)) }.to raise_error(described_class::Invalid, /PLN snapshot/)
  end
end
