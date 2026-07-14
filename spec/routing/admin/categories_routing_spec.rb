# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin category product routes", type: :routing do
  it "routes the legacy GET remove_product URL" do
    expect(get: "/admin/categories/21961/remove_product?product_id=24162").to be_routable
  end

  it "keeps the POST remove_product route" do
    expect(post: "/admin/categories/21961/remove_product?product_id=24162").to be_routable
  end
end
