# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmailTemplates::Renderer do
  let(:user) { create(:user, username: "Иван", first_name: "Иван") }
  let(:order) { create(:order, user: user, public_uid: "7654321") }

  before do
    create(:order_item, order: order, product_sku: "123", quantity: 1, price: 10.0)
  end

  it "renders order_created template with user name and order number" do
    html = described_class.render(:order_created, order: order, user: user)

    expect(html).to include("Иван")
    expect(html).to include("№7654321")
  end

  it "maps paid status to order_placed template" do
    expect(described_class.template_for_status("paid")).to eq(:order_placed)
    expect(described_class.template_for_status("shipped")).to eq(:shipped_to_pvz)
    expect(described_class.template_for_status("cancelled")).to eq(:order_cancelled)
  end
end
