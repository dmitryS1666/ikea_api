# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrmSyncJob, type: :job do
  before do
    allow(CrmIntegrationService).to receive(:sync_user)
    allow(CrmIntegrationService).to receive(:sync_order)
    allow(CrmIntegrationService).to receive(:notify_return)
    allow(CrmIntegrationService).to receive(:notify_cooperation)
  end

  describe "#perform" do
    it "syncs user" do
      user = create(:user)

      described_class.perform_now("User", user.id)

      expect(CrmIntegrationService).to have_received(:sync_user).with(user)
    end

    it "syncs order" do
      order = create(:order)

      described_class.perform_now("Order", order.id)

      expect(CrmIntegrationService).to have_received(:sync_order).with(order)
    end

    it "notifies AmoCRM about return request" do
      return_request = create(:return_request)

      described_class.perform_now("ReturnRequest", return_request.id)

      expect(CrmIntegrationService).to have_received(:notify_return).with(return_request)
    end

    it "notifies AmoCRM about cooperation request" do
      cooperation_request = create(:cooperation_request)

      described_class.perform_now("CooperationRequest", cooperation_request.id)

      expect(CrmIntegrationService).to have_received(:notify_cooperation).with(cooperation_request)
    end

    it "no-ops when entity is missing" do
      described_class.perform_now("User", -1)
      described_class.perform_now("Order", -1)
      described_class.perform_now("ReturnRequest", -1)
      described_class.perform_now("CooperationRequest", -1)

      expect(CrmIntegrationService).not_to have_received(:sync_user)
      expect(CrmIntegrationService).not_to have_received(:sync_order)
      expect(CrmIntegrationService).not_to have_received(:notify_return)
      expect(CrmIntegrationService).not_to have_received(:notify_cooperation)
    end

    it "re-raises errors for retry" do
      user = create(:user)
      allow(CrmIntegrationService).to receive(:sync_user).and_raise(StandardError, "boom")

      expect { described_class.perform_now("User", user.id) }.to raise_error(StandardError, "boom")
    end
  end
end
