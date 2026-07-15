# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seeds::AdminRoleUsers do
  it "idempotently creates every role from the approved matrix" do
    first_result = described_class.call(environment: {}, production: false)
    second_result = described_class.call(environment: {}, production: false)

    expect(first_result.pluck(:status)).to all(eq(:saved))
    expect(second_result.pluck(:status)).to all(eq(:saved))
    expect(User.where(username: described_class::USERS.pluck(:username)).count).to eq(7)
    expect(User.find_by!(username: "director")).to have_attributes(first_name: "Владимир", role: "admin")
    expect(User.where(username: described_class::USERS.pluck(:username)).pluck(:role)).to match_array(
      %w[admin site_admin manager_requests content_manager accountant technician observer]
    )
  end

  it "requires explicit passwords for new production accounts" do
    result = described_class.call(environment: {}, production: true)

    expect(result.pluck(:status)).to all(eq(:skipped))
    expect(User.where(username: described_class::USERS.pluck(:username))).to be_empty
  end

  it "does not reset an existing password during an idempotent seed" do
    described_class.call(environment: { "DIRECTOR_PASSWORD" => "Initial-password-42" }, production: true)
    director = User.find_by!(username: "director")

    described_class.call(environment: {}, production: true)

    expect(director.reload.authenticate("Initial-password-42")).to eq(director)
  end
end
