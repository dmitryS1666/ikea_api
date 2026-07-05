# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::QueryTerms do
  it "adds singular stem and configured aliases for Russian plural ending in -ы" do
    expect(described_class.for("шкафы")).to include("шкафы", "шкаф", "гардероб", "pax", "пакс")
  end

  it "keeps original term and configured aliases for known non-plural queries" do
    expect(described_class.for("шкаф")).to include("шкаф", "гардероб", "pax", "пакс")
  end

  it "keeps single term for unknown queries" do
    expect(described_class.for("коврик")).to eq(%w[коврик])
  end

  it "builds independent term groups for multi-word queries" do
    groups = described_class.groups_for("Kallax стеллаж")

    expect(groups.size).to eq(2)
    expect(groups.first.map(&:downcase)).to include("kallax")
    expect(groups.second).to include("стеллаж", "полка")
  end
end
