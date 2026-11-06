# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product, "content_updated_at" do
  it "stays in place when a sync rewrites the same price and stock" do
    product = create(:product, price: 10, quantity: 5)
    stamped = Time.zone.parse("2026-09-23 10:00")
    product.update_columns(updated_at: Time.zone.parse("2026-11-05 10:00"), content_updated_at: stamped)

    product.update_columns(updated_at: Time.zone.parse("2026-11-06 10:00"), quantity: 5, price: 10)

    expect(product.reload.content_updated_at).to eq(stamped)
  end

  it "moves when the published price changes" do
    product = create(:product, price: 10)
    product.update_columns(content_updated_at: Time.zone.parse("2026-09-23 10:00"))

    product.update!(price: 12)

    expect(product.reload.content_updated_at).to be > Time.zone.parse("2026-09-23 10:00")
  end
end
