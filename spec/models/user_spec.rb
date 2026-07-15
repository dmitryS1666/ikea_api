# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  include ActiveJob::TestHelper

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end
  describe ".normalize_gender" do
    it "maps lowercase and localized aliases to canonical values" do
      expect(described_class.normalize_gender("male")).to eq("Male")
      expect(described_class.normalize_gender("female")).to eq("Female")
      expect(described_class.normalize_gender("Мужской")).to eq("Male")
      expect(described_class.normalize_gender("женский")).to eq("Female")
    end

    it "keeps canonical values unchanged" do
      expect(described_class.normalize_gender("Male")).to eq("Male")
      expect(described_class.normalize_gender("Female")).to eq("Female")
    end
  end

  describe "#gender" do
    it "returns canonical value for legacy lowercase storage" do
      user = build(:user, gender: "male")
      user.write_attribute(:gender, "male")

      expect(user.gender).to eq("Male")
    end
  end

  describe "admin permissions" do
    it "normalizes legacy manager role to manager_requests" do
      user = build(:user, role: "manager")
      user.valid?

      expect(user.role).to eq("manager_requests")
    end

    it "allows manager_requests to manage orders but not content" do
      user = build(:user, role: "manager_requests")

      expect(user.has_admin_permission?(:orders_manage)).to be(true)
      expect(user.has_admin_permission?(:content_manage)).to be(false)
    end

    it "applies custom permissions overrides" do
      user = build(:user, role: "observer", custom_permissions: { content_manage: true })

      expect(user.has_admin_permission?(:content_manage)).to be(true)
      expect(user.has_admin_permission?(:orders_manage)).to be(false)
    end

    it "checks access by admin resource and action" do
      accountant = build(:user, role: "accountant", is_active: true)

      expect(accountant.allowed_for_admin_resource?("orders", "index")).to be(true)
      expect(accountant.allowed_for_admin_resource?("orders", "update")).to be(false)
    end
  end

  describe "#destroy" do
    it "detaches orders instead of blocking deletion" do
      user = create(:user)
      order = create(:order, user: user)

      expect { user.destroy! }.to change(described_class, :count).by(-1)
      expect(order.reload.user_id).to be_nil
    end

    it "destroys reviews and helpful votes" do
      user = create(:user)
      review = create(:review, user: user)
      other_user = create(:user)
      other_review = create(:review, user: other_user)
      vote = ReviewHelpfulVote.create!(review: other_review, user: user)

      expect { user.destroy! }.to change(described_class, :count).by(-1)
        .and change(Review, :count).by(-1)
        .and change(ReviewHelpfulVote, :count).by(-1)

      expect(Review.exists?(review.id)).to be(false)
      expect(Review.exists?(other_review.id)).to be(true)
      expect(ReviewHelpfulVote.exists?(vote.id)).to be(false)
    end

    it "nullifies search query logs" do
      user = create(:user)
      log = SearchQueryLog.create!(customer: user, query: "стол")

      user.destroy!

      expect(log.reload.customer_id).to be_nil
    end
  end

  describe "consent CRM sync" do
    it "enqueues CrmSyncJob when newsletter consent changes" do
      user = create(:user, newsletter_consent: true)

      expect do
        user.update!(newsletter_consent: false)
      end.to have_enqueued_job(CrmSyncJob).with("User", user.id)
    end

    it "enqueues CrmSyncJob when email_marketing changes" do
      user = create(:user, email_marketing: true)

      expect do
        user.update!(email_marketing: false)
      end.to have_enqueued_job(CrmSyncJob).with("User", user.id)
    end

    it "does not enqueue CrmSyncJob when unrelated profile field changes" do
      user = create(:user, city: "Минск")

      expect do
        user.update!(city: "Гродно")
      end.not_to have_enqueued_job(CrmSyncJob)
    end
  end

  describe "#email_marketing_enabled=" do
    it "treats either legacy email flag as an active subscription" do
      user = build(:user, email_marketing: false, newsletter_consent: true)

      expect(user.email_marketing_enabled?).to be(true)
    end

    it "enables both email consent fields" do
      user = build(:user, email_marketing: false, newsletter_consent: false)

      user.email_marketing_enabled = "1"

      expect(user.email_marketing).to be(true)
      expect(user.newsletter_consent).to be(true)
    end

    it "disables both email consent fields" do
      user = build(:user, email_marketing: true, newsletter_consent: true)

      user.email_marketing_enabled = "0"

      expect(user.email_marketing).to be(false)
      expect(user.newsletter_consent).to be(false)
    end
  end
end
