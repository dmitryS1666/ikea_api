require "rails_helper"

RSpec.describe Categories::AvailableFiltersImportService do
  describe "#call" do
    it "updates available_filters for matched categories" do
      category = create(:category, ikea_id: "48982", available_filters: [])

      payload = {
        categories: [
          {
            ikea_id: "48982",
            available_filters: [
              {
                parameter: "f-type",
                name: "Typ",
                values: [
                  { id: "50309", name: "Do zabudowy" }
                ]
              }
            ]
          }
        ]
      }

      result = described_class.new(StringIO.new(payload.to_json)).call

      expect(result.updated).to eq(1)
      expect(category.reload.available_filters).to eq(payload[:categories].first[:available_filters])
    end
  end
end
