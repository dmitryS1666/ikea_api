require "rails_helper"

RSpec.describe Categories::TreeBuilder do
  describe "#call" do
    it "builds tree using relation with limited select" do
      root = create(
        :category,
        ikea_id: "root-1",
        name: "Root",
        translated_name: "Root",
        cached_slug: "root",
        parent_ids: [],
        root_position: 1
      )
      child = create(
        :category,
        ikea_id: "child-1",
        name: "Child",
        translated_name: "Child",
        cached_slug: "child",
        parent_ids: [root.ikea_id]
      )

      scope = Category
        .where(ikea_id: [root.ikea_id, child.ikea_id])
        .select(:id, :ikea_id, :translated_name, :cached_slug, :parent_ids, :top_position, :root_position, :name)
        .with_attached_icon
        .with_attached_pictogram

      result = described_class.new(scope).call

      expect(result).to include(:data)
      expect(result[:data].size).to eq(1)

      root_node = result[:data].first
      expect(root_node[:id]).to eq(root.ikea_id)
      expect(root_node.dig(:attributes, :translated_name)).to eq("Root")
      expect(root_node.dig(:attributes, :slug)).to eq("root")

      expect(root_node[:children].size).to eq(1)
      expect(root_node[:children].first[:id]).to eq(child.ikea_id)
      expect(root_node[:children].first.dig(:attributes, :slug)).to eq("child")
    end
  end
end
