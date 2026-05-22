# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContentArticleHtmlNormalizer do
  describe ".normalize" do
    it "adds font-weight to li when the whole item is wrapped in strong" do
      html = "<ol><li><strong>Пункт 1</strong></li><li>обычный</li></ol>"
      result = described_class.normalize(html)

      expect(result).to include('font-weight:700')
      expect(result).to include("<strong>Пункт 1</strong>")
      expect(result).not_to match(/<li[^>]*font-weight[^>]*>обычный/)
    end

    it "does not change li when only part of the text is bold" do
      html = "<ol><li>текст <strong>жирный</strong></li></ol>"
      result = described_class.normalize(html)

      expect(result).not_to include("font-weight:700")
    end

    it "handles unordered lists" do
      html = "<ul><li><b>Item</b></li></ul>"
      result = described_class.normalize(html)

      expect(result).to include("font-weight:700")
    end

    it "returns blank input unchanged" do
      expect(described_class.normalize("")).to eq("")
      expect(described_class.normalize(nil)).to eq("")
    end
  end
end
