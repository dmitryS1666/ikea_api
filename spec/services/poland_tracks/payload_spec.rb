require "rails_helper"

RSpec.describe PolandTracks::Payload do
  def payload
    {
      "delivery_type" => 1, "weight" => "1000", "nomerikea" => "12345678",
      "europost_track" => "BY000000000BY", "pvz" => 12345,
      "recipient" => {
        "first_name" => "Иван", "last_name" => "Иванов", "email" => "test@example.com",
        "phone" => "+375291112233", "phone_country" => "by", "birthdate" => "01.01.1990",
        "document_country" => "by", "address_country" => "by", "passport_serial" => "AB",
        "passport_number" => "1234567", "iin" => "1234567A123AB1", "passport_date" => "01.01.2015",
        "passport_founder" => "РОВД", "region" => "Минская", "city" => "Минск", "street" => "Ленина",
        "building" => "1", "index" => "220000"
      },
      "items" => [{ "name" => "Стеллаж", "count" => 1, "price" => 99.99, "link" => "https://www.ikea.com/pl/pl/p/example-123/" }]
    }
  end

  it "accepts BY and optional recipient fields omitted" do
    expect(described_class.validate!(payload)).to be(true)
  end

  [4, 5].each do |type|
    it "requires a delivery address for delivery_type #{type}" do
      data = payload.merge("delivery_type" => type).except("pvz")
      data.delete("europost_track") if type == 5
      expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /delivery_address/)
    end
  end

  [1, 4].each do |type|
    it "requires a Europost track for delivery_type #{type}" do
      data = payload.merge("delivery_type" => type).except("europost_track")
      data = data.except("pvz").merge("delivery_address" => "Минск, Ленина, д. 1") if type == 4
      expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /europost_track/)
    end
  end

  it "requires a numeric provider PVZ ID for type 1" do
    expect { described_class.validate!(payload.except("pvz")) }.to raise_error(described_class::Invalid, /pvz/)
  end

  it "rejects irrelevant Europost keys for IKEYA delivery" do
    data = payload.merge("delivery_type" => 5, "delivery_address" => "Минск, Ленина, д. 1").except("pvz")
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /europost_track/)
  end

  it "accepts RU documents without optional INN" do
    data = payload
    data["recipient"].merge!("document_country" => "ru", "address_country" => "ru", "passport_serial" => "4510",
                             "passport_number" => "123456", "iin" => nil, "phone_country" => "ru", "phone" => "+79991112233")
    expect(described_class.validate!(data)).to be(true)
  end

  it "requires BY personal number" do
    data = payload
    data["recipient"].delete("iin")
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /iin/)
  end

  it "rejects nonexistent calendar dates" do
    data = payload
    data["recipient"]["birthdate"] = "31.02.1990"
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /birthdate/)
  end

  [0, 0.99, nil].each do |price|
    it "rejects PLN price #{price.inspect}" do
      data = payload
      data["items"].first["price"] = price
      expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /PLN/)
    end
  end

  it "rejects fractional quantities" do
    data = payload
    data["items"].first["count"] = 1.5
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid)
  end

  it "rejects unsupported countries" do
    data = payload
    data["recipient"]["address_country"] = "kz"
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /address_country/)
  end

  it "rejects an empty goods list" do
    data = payload
    data["items"] = []
    expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /items/)
  end

  it "preserves the exact original request on a reconciled retry" do
    original = payload
    export = instance_double(PolandTrackExport, payload_json: original.to_json)
    expect(export).not_to receive(:order)
    expect(described_class.for_export(export)).to eq(original)
  end

  it "rejects missing or non-positive weight" do
    [nil, "", "0", 1000, "1000.5", "-1"].each do |weight|
      data = payload.merge("weight" => weight)
      expect { described_class.validate!(data) }.to raise_error(described_class::Invalid, /weight/)
    end
  end

  it "fills missing weight from the order before export" do
    order = instance_double(Order, weight: 2.5, address_json: {}, pricing_snapshot: nil,
                                   resolved_track_number: "BY000000000BY",
                                   tracking_info: nil)
    original = payload.except("weight")
    export = instance_double(PolandTrackExport, payload_json: original.to_json, order: order)
    expect(described_class.for_export(export)).to include("delivery_type" => 1, "weight" => "2500")
  end

  it "fills missing item PLN and link from catalog-backed order items" do
    product = create(:product, price: 149.5, url: "https://www.ikea.com/pl/pl/p/healed-123/")
    order = create(:order, track_number: "BY000000000BY",
                           address_json: { "pickup_point_id" => "70130090" })
    item = create(:order_item, order: order, product_sku: product.sku, quantity: 2,
                               poland_price_pln: nil, poland_product_url: nil)
    item.update_columns(poland_price_pln: nil, poland_product_url: nil)
    original = payload.merge("items" => [{ "name" => "Стеллаж", "count" => 2, "price" => nil, "link" => nil }])
    export = PolandTrackExport.create!(order: order, payload_json: original.to_json)
    result = described_class.for_export(export)
    expect(result["items"].first).to include("price" => 149.5, "link" => product.url, "count" => 2)
    expect(item.reload.poland_price_pln.to_f).to eq(149.5)
    expect(item.poland_product_url).to eq(product.url)
  end

  it "uses catalog title with small_desc_name for ShopByShop item names" do
    product = create(
      :product,
      name: "IKEA PS 2026",
      name_ru: "IKEA PS 2026",
      small_desc_name: "Стол, зеленый, 96 см",
      price: 199.0,
      url: "https://www.ikea.com/pl/pl/p/ps-table-123/"
    )
    order = create(:order)
    create(:order_item, order: order, product_sku: product.sku, quantity: 1)
    rows = described_class.item_rows(order)
    expect(rows.first["name"]).to eq("IKEA PS 2026 Стол, зеленый, 96 см")
  end

  it "refreshes short item names from catalog when healing older snapshots" do
    product = create(
      :product,
      name_ru: "IKEA PS 2026",
      small_desc_name: "Стол, зеленый, 96 см",
      price: 149.5,
      url: "https://www.ikea.com/pl/pl/p/healed-name-123/"
    )
    order = create(:order, track_number: "BY000000000BY",
                           address_json: { "pickup_point_id" => "70130090" })
    create(:order_item, order: order, product_sku: product.sku, quantity: 1,
                        poland_price_pln: nil, poland_product_url: nil)
    original = payload.merge("items" => [{ "name" => "Стол", "count" => 1, "price" => nil, "link" => nil }])
    export = PolandTrackExport.create!(order: order, payload_json: original.to_json)
    result = described_class.for_export(export)
    expect(result["items"].first["name"]).to eq("IKEA PS 2026 Стол, зеленый, 96 см")
  end

  it "places weight immediately after delivery_type" do
    keys = described_class.with_weight({ "delivery_type" => 5, "nomerikea" => "1" }, "1000").keys
    expect(keys.take(2)).to eq(%w[delivery_type weight])
  end

  it "refreshes item names on a pending export payload without requiring heal" do
    product = create(
      :product,
      name_ru: "IKEA PS 2026",
      small_desc_name: "Стол, зеленый, 96 см",
      price: 149.5,
      url: "https://www.ikea.com/pl/pl/p/name-refresh-123/"
    )
    order = create(:order, track_number: "BY000000000BY",
                           address_json: { "pickup_point_id" => "70130090" })
    create(:order_item, order: order, product_sku: product.sku, quantity: 1,
                        poland_price_pln: 149.5, poland_product_url: product.url)
    original = payload.merge("items" => [{
      "name" => "Стол", "count" => 1, "price" => 149.5, "link" => product.url
    }])
    export = PolandTrackExport.create!(order: order, payload_json: original.to_json, state: "pending")

    result = described_class.refresh_export_item_names!(export, persist: true)
    expect(result[:changed]).to be(true)
    expect(JSON.parse(export.reload.payload_json).dig("items", 0, "name"))
      .to eq("IKEA PS 2026 Стол, зеленый, 96 см")
  end
end
