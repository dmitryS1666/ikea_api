# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardStats do
  describe "role-sensitive data" do
    let(:order) do
      instance_double(
        Order,
        id: 10,
        customer_name: "Иван Иванов",
        total_amount: BigDecimal("120.50"),
        status: "created",
        created_at: Time.zone.parse("2026-07-15 10:00:00")
      )
    end

    before do
      relation = instance_double(ActiveRecord::Relation)
      allow(Order).to receive(:order).with(created_at: :desc).and_return(relation)
      allow(relation).to receive(:limit).with(4).and_return([order])
    end

    it "masks customer names and removes access to financial dashboard widgets for an observer" do
      observer = build(:user, role: "observer", is_active: true)
      service = described_class.new(user: observer)

      expect(service.send(:recent_orders).first[:customer]).to eq("Скрыто")
      expect(service.send(:finance_access?)).to be(false)
    end

    it "keeps personal and financial dashboard data for the owner" do
      owner = build(:user, role: "admin", is_active: true)
      service = described_class.new(user: owner)

      expect(service.send(:recent_orders).first[:customer]).to eq("Иван Иванов")
      expect(service.send(:finance_access?)).to be(true)
    end

    it "does not expose customer names to an accountant on the aggregate dashboard" do
      accountant = build(:user, role: "accountant", is_active: true)
      service = described_class.new(user: accountant)

      expect(service.send(:recent_orders).first[:customer]).to eq("Скрыто")
      expect(service.send(:finance_access?)).to be(true)
    end
  end
end
