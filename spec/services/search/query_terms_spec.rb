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
end
