# frozen_string_literal: true

require "rails_helper"

RSpec.describe Search::QueryTerms do
  it "adds singular stem for Russian plural ending in -ы" do
    expect(described_class.for("шкафы")).to eq(%w[шкафы шкаф])
  end

  it "keeps single term for non-plural queries" do
    expect(described_class.for("шкаф")).to eq(%w[шкаф])
  end
end
