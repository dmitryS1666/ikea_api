# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::FinanceRegistryExport do
  it "exports the minimal accountant registry without customer personal data" do
    order = create(:order, total_amount: 50.75, full_name: "Секретный Клиент", phone: "+375291112233")

    csv = described_class.call(FinanceEntry.where(order: order))
    parsed = CSV.parse(csv.delete_prefix("\uFEFF"), headers: true, col_sep: ";")

    expect(parsed.headers).to eq(described_class::HEADERS)
    expect(parsed.first["ID заказа"]).to eq(order.id.to_s)
    expect(parsed.first["Сумма"]).to eq("50.75")
    expect(csv).not_to include("Секретный Клиент", "+375291112233")
  end
end
