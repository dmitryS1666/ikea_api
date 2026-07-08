# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConsentService do
  let(:user) { create(:user) }
  let!(:personal_data_page) do
    LegalPage.create!(
      title: "ПД",
      slug: LegalPage::SLUG_PERSONAL_DATA,
      body: "body",
      status: :published,
      updated_at: Time.zone.parse("2026-01-15 10:00:00")
    )
  end
  let!(:offer_page) do
    LegalPage.create!(
      title: "Оферта",
      slug: LegalPage::SLUG_PUBLIC_OFFER,
      body: "body",
      status: :published,
      updated_at: Time.zone.parse("2026-02-01 12:00:00")
    )
  end
  let!(:broker_page) do
    LegalPage.create!(
      title: "Брокер",
      slug: LegalPage::SLUG_CUSTOMS_BROKER,
      body: "body",
      status: :published,
      updated_at: Time.zone.parse("2026-03-01 09:00:00")
    )
  end

  describe ".validate_checkout_consents!" do
    it "returns nil when all required consents are accepted" do
      result = described_class.validate_checkout_consents!({
        personal_data_consent: true,
        offer_agreement_consent: true,
        customs_broker_consent: true
      })

      expect(result).to be_nil
    end

    it "returns error when offer agreement is missing" do
      result = described_class.validate_checkout_consents!({
        personal_data_consent: true,
        offer_agreement_consent: false,
        customs_broker_consent: true
      })

      expect(result[:code]).to eq("consent_required")
      expect(result[:field]).to eq("offer_agreement_consent")
    end

    it "accepts personal data consent from registered user when params omit it" do
      registered_user = create(:user, personal_data_consent: true, personal_data_consented_at: 1.day.ago)

      result = described_class.validate_checkout_consents!({}, user: registered_user)

      expect(result).to be_nil
    end

    it "does not require personal data consent at checkout" do
      result = described_class.validate_checkout_consents!({
        offer_agreement_consent: true,
        customs_broker_consent: true
      }, user: user)

      expect(result).to be_nil
    end
  end

  describe ".record_checkout_consents!" do
    let(:order) { create(:order, user: user) }

    it "stores order snapshot and consent history with document versions" do
      described_class.record_checkout_consents!(
        user: user,
        order: order,
        params: {
          personal_data_consent: true,
          offer_agreement_consent: true,
          customs_broker_consent: true
        }
      )

      order.reload
      user.reload

      expect(order.personal_data_consent).to be(true)
      expect(order.offer_agreement_consent).to be(true)
      expect(order.customs_broker_consent).to be(true)
      expect(user.personal_data_consent).to be(true)
      expect(user.personal_data_consented_at).to be_present

      records = ConsentRecord.where(order: order).order(:consent_type)
      expect(records.count).to eq(3)
      expect(records.map(&:legal_page_slug)).to contain_exactly(
        LegalPage::SLUG_PERSONAL_DATA,
        LegalPage::SLUG_PUBLIC_OFFER,
        LegalPage::SLUG_CUSTOMS_BROKER
      )
      expect(records.find_by(consent_type: "offer_agreement").legal_page_version_at)
        .to eq(offer_page.updated_at)
    end

    it "records personal data consent from registered user when params omit it" do
      user.update!(personal_data_consent: true, personal_data_consented_at: 2.days.ago)
      consented_at = user.personal_data_consented_at

      described_class.record_checkout_consents!(
        user: user,
        order: order,
        params: {}
      )

      order.reload
      user.reload

      expect(order.personal_data_consent).to be(true)
      expect(order.offer_agreement_consent).to be(true)
      expect(order.customs_broker_consent).to be(true)
      expect(ConsentRecord.where(order: order).count).to eq(3)
      expect(user.personal_data_consented_at).to eq(consented_at)
    end
  end

  describe ".record_registration_personal_data!" do
    it "creates consent history and updates user" do
      described_class.record_registration_personal_data!(user: user)

      user.reload
      expect(user.personal_data_consent).to be(true)
      expect(user.consent_records.for_type(:personal_data).last.source).to eq("registration")
    end
  end
end
