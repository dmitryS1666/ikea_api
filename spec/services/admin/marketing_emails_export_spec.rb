# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::MarketingEmailsExport do
  it "exports only users with email and marketing consent" do
    subscribed = create(
      :user,
      email: "subscribed@example.com",
      first_name: "Иван",
      last_name: "Иванов",
      email_marketing: true,
      newsletter_consent: false
    )
    create(
      :user,
      email: "legacy@example.com",
      email_marketing: false,
      newsletter_consent: true
    )
    create(
      :user,
      email: "unsubscribed@example.com",
      email_marketing: false,
      newsletter_consent: false
    )
    create(
      :user,
      email: nil,
      email_marketing: true,
      newsletter_consent: true,
      phone: "375291000001"
    )

    csv = described_class.call
    parsed = CSV.parse(csv.delete_prefix("\uFEFF"), headers: true, col_sep: ";")

    expect(parsed.headers).to eq(described_class::HEADERS)
    expect(parsed.map { |row| row["Email"] }).to contain_exactly(
      "subscribed@example.com",
      "legacy@example.com"
    )
    expect(parsed.map { |row| row["Email"] }).not_to include("unsubscribed@example.com")

    subscribed_row = parsed.find { |row| row["Email"] == subscribed.email }
    expect(subscribed_row["ID пользователя"]).to eq(subscribed.id.to_s)
    expect(subscribed_row["Имя"]).to eq("Иван")
    expect(subscribed_row["Фамилия"]).to eq("Иванов")
  end
end
