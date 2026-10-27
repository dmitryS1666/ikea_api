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

  it "keeps a dotted IKEA article as one number" do
    groups = described_class.groups_for("296.220.94")

    expect(groups.size).to eq(1)
    expect(groups.flatten).to eq(["29622094"])
    expect(described_class.for("296.220.94")).not_to include("296", "220", "94")
  end

  it "keeps a dotted article intact inside a longer query" do
    groups = described_class.groups_for("кухня 296.220.94")

    expect(groups.map { |group| group.map(&:downcase) }).to include(["29622094"])
    expect(groups.flatten).not_to include("296", "220", "94")
  end

  it "builds independent term groups for multi-word queries" do
    groups = described_class.groups_for("Kallax стеллаж")

    expect(groups.size).to eq(2)
    expect(groups.first.map(&:downcase)).to include("kallax")
    expect(groups.second).to include("стеллаж", "полка")
  end
end
