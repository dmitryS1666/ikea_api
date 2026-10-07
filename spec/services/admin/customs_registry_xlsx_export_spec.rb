# frozen_string_literal: true

require "rails_helper"
require "axlsx"

RSpec.describe Admin::CustomsRegistryXlsxExport do
  def read_sheet(xlsx_bytes)
    path = Rails.root.join("tmp", "customs-registry-spec-#{SecureRandom.hex(4)}.xlsx")
    File.binwrite(path, xlsx_bytes)
    workbook = Roo::Excelx.new(path.to_s)
    sheet = workbook.sheet(0)
    headers = sheet.row(1)
    rows = (2..sheet.last_row).map { |i| sheet.row(i) }
    { headers: headers, rows: rows }
  ensure
    FileUtils.rm_f(path) if path
  end

  it "builds a registry workbook for paid orders in the selected period" do
    user = create(
      :user,
      first_name: "Иван",
      last_name: "Иванов",
      middle_name: "Иванович",
      email: "ivan@example.com",
      phone: "+375291112233",
      region: "Минская",
      city: "Минск",
      street: "Берута",
      house: "6",
      building: "1",
      apartment: "351",
      postcode: "220092",
      country_code: "RB",
      dob: Date.new(1990, 1, 15),
      personal_data_consented_at: Time.zone.parse("2024-01-10 12:00")
    )
    user.update!(
      encrypted_passport_json: {
        series: "AB",
        passport_number: "1234567",
        issued_date: "01.02.2015",
        issued_by: "РОВД",
        iin: "3150190A001PB1"
      }.to_json
    )

    product = create(:product, sku: "s90499132", name: "LAMP", weight: 2.15, price: 179.0)
    order = create(
      :order,
      user: user,
      status: :paid,
      created_at: Time.zone.parse("2025-06-05 10:00"),
      track_number: "BY080050929171",
      weight: 2.15,
      phone: "+375291112233",
      address_json: {
        "pickup_point_id" => "12345",
        "delivery" => {
          "pickup_point" => { "city" => "Минск", "name" => "ОПС", "address" => "ул. Тест 1" }
        }
      }
    )
    create(
      :order_item,
      order: order,
      product_sku: product.sku,
      quantity: 1,
      price: 50.0,
      poland_price_pln: 179.0,
      name_snapshot: "Светодиодная лампа"
    )

    # Outside period — must be ignored
    create(:order, user: user, status: :paid, created_at: Time.zone.parse("2024-01-01"))

    result = described_class.call(from_date: "2025-06-01", to_date: "2025-06-30")
    parsed = read_sheet(result.xlsx)

    expect(result.orders_count).to eq(1)
    expect(result.rows_count).to eq(1)
    expect(parsed[:headers]).to eq(described_class::HEADERS)

    row = parsed[:rows].first
    expect(row[0]).to eq("GP#{order.id.to_s.rjust(9, '0')}PL")
    expect(row[1]).to eq("BY080050929171")
    expect(row[2].to_i).to eq(1)
    expect(row[3]).to eq("Package-#{order.id}")
    expect(row[4]).to include("Иванов")
    expect(row[5]).to eq("ivan@example.com")
    expect(row[7]).to eq("AB")
    expect(row[8]).to eq("1234567")
    expect(row[21]).to eq("Н/Д") # ТН ВЭД
    expect(row[22]).to eq("Н/Д")
    expect(row[23].to_i).to eq(1)
    expect(row[25]).to eq("ikea")
    expect(row[26]).to eq("o/s")
    expect(row[28].to_s).to eq("179.00")
    expect(row[31]).to eq("PLN")
    expect(row[40]).to eq("Н/Д") # адрес продавца
    expect(row[43]).to eq("ikeya.by")
    expect(row[44]).to eq("Минская")
    expect(row[53]).to include("персональных данных")
    expect(row[54]).to include("Таможенного представителя")
  end

  it "rejects an inverted date range" do
    expect {
      described_class.call(from_date: "2025-06-30", to_date: "2025-06-01")
    }.to raise_error(ArgumentError, /не может быть раньше/)
  end
end
