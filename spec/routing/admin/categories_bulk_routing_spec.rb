# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin category bulk product routes", type: :routing do
  it "routes bulk product removal through POST" do
    expect(post: "/admin/categories/21961/remove_products").to be_routable
  end
end
