# frozen_string_literal: true

require "rails_helper"

RSpec.describe "User::ADMIN_EXPORT_ACTIONS" do
  it "contains all supported admin export actions" do
    expect(User::ADMIN_EXPORT_ACTIONS.fetch("products")).to include("download_products_xlsx")
    expect(User::ADMIN_EXPORT_ACTIONS.fetch("finance_entries")).to include("export_registry")
    expect(User::ADMIN_EXPORT_ACTIONS.fetch("users")).to include("export_marketing_emails")
  end

  it "does not classify an unregistered action as an export" do
    expect(User::ADMIN_EXPORT_ACTIONS.fetch("orders", [])).not_to include("future_export")
  end
end
