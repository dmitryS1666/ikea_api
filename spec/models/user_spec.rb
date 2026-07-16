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
    it "defines every role from the approved role matrix" do
      expect(described_class::ROLE_OPTIONS.values).to include(
        "admin",
        "site_admin",
        "manager_requests",
        "content_manager",
        "accountant",
        "technician",
        "observer"
      )
    end

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
      expect(accountant.allowed_for_admin_resource?("return_requests", "index")).to be(false)
      expect(accountant.allowed_for_admin_resource?("exchange_rates", "index")).to be(true)
      expect(accountant.allowed_for_admin_resource?("exchange_rates", "update")).to be(false)
      expect(accountant.allowed_for_admin_resource?("parser_control", "index")).to be(false)
    end

    it "limits the site administrator to content, orders and basic reports" do
      user = build(:user, role: "site_admin", is_active: true)

      expect(user.allowed_for_admin_resource?("products", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("orders", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("dashboard", "index")).to be(true)
      expect(user.allowed_for_admin_resource?("exchange_rates", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("parser_control", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("users", "index")).to be(false)
    end

    it "limits the request manager to processing orders and requests" do
      user = build(:user, role: "manager_requests", is_active: true)

      expect(user.allowed_for_admin_resource?("orders", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("return_requests", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("cooperation_requests", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("favorites", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("products", "index")).to be(false)
      expect(user.admin_landing_resource).to eq("orders")
    end

    it "limits the content manager to content without dashboard or personal data" do
      user = build(:user, role: "content_manager", is_active: true)

      expect(user.allowed_for_admin_resource?("products", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("breadcrumb_rules", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("featured_product_tabs", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("reviews", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("dashboard", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("orders", "index")).to be(false)
      expect(user.can_view_personal_data?).to be(false)
      expect(user.admin_landing_resource).to eq("products")
    end

    it "gives the technician only technical sections" do
      user = build(:user, role: "technician", is_active: true)

      expect(user.allowed_for_admin_resource?("parser_control", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("cron_schedules", "update")).to be(true)
      expect(user.allowed_for_admin_resource?("orders", "index")).to be(false)
      expect(user.allowed_for_admin_resource?("products", "index")).to be(false)
      expect(user.admin_landing_resource).to eq("parser_control")
    end

    it "keeps the observer read-only and without personal data" do
      user = build(:user, role: "observer", is_active: true)

      expect(user.allowed_for_admin_resource?("dashboard", "index")).to be(true)
      expect(user.allowed_for_admin_resource?("orders", "show")).to be(true)
      expect(user.allowed_for_admin_resource?("orders", "update")).to be(false)
      expect(user.allowed_for_admin_resource?("products", "index")).to be(false)
      expect(user.can_view_personal_data?).to be(false)
    end

    it "reserves destructive actions for the owner by default" do
      site_admin = build(:user, role: "site_admin", is_active: true)
      owner = build(:user, role: "admin", is_active: true)

      expect(site_admin.allowed_for_admin_resource?("products", "destroy")).to be(false)
      expect(site_admin.allowed_for_admin_resource?("categories", "remove_product")).to be(false)
      expect(owner.allowed_for_admin_resource?("products", "destroy")).to be(true)
    end

    it "requires a separate permission for data exports" do
      content_manager = build(:user, role: "content_manager", is_active: true)
      accountant = build(:user, role: "accountant", is_active: true)
      owner = build(:user, role: "admin", is_active: true)
      site_admin = build(:user, role: "site_admin", is_active: true)

      expect(content_manager.allowed_for_admin_resource?("products", "download_products_xlsx")).to be(false)
      expect(accountant.allowed_for_admin_resource?("finance_entries", "export_registry")).to be(true)
      expect(accountant.allowed_for_admin_resource?("orders", "export_registry")).to be(false)
      expect(owner.allowed_for_admin_resource?("products", "download_products_xlsx")).to be(true)
      expect(owner.allowed_for_admin_resource?("users", "export_marketing_emails")).to be(true)
      expect(site_admin.allowed_for_admin_resource?("users", "export_marketing_emails")).to be(false)
    end

    it "limits the audit log to the owner" do
      owner = build(:user, role: "admin", is_active: true)
      site_admin = build(:user, role: "site_admin", is_active: true)

      expect(owner.allowed_for_admin_resource?("admin_audit_logs", "index")).to be(true)
      expect(site_admin.allowed_for_admin_resource?("admin_audit_logs", "index")).to be(false)
    end

    it "denies admin resources that have no explicit rule" do
      user = build(:user, role: "site_admin", is_active: true)

      expect(user.allowed_for_admin_resource?("unregistered_section", "index")).to be(false)
    end
  end

  describe "#destroy" do
    it "destroys orders and their status history" do
      user = create(:user)
      order = create(:order, user: user)
      event_ids = order.order_status_events.pluck(:id)
      expect(event_ids).not_to be_empty

      expect { user.destroy! }.to change(described_class, :count).by(-1)
        .and change(Order, :count).by(-1)

      expect(Order.exists?(order.id)).to be(false)
      expect(OrderStatusEvent.where(id: event_ids)).to be_empty
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

    it "destroys email verification tokens instead of blocking deletion" do
      user = create(:user, email: "delete-me@example.com")
      token = EmailVerificationToken.create!(
        user: user,
        email: user.email,
        token: SecureRandom.hex(16),
        purpose: "welcome",
        expires_at: 1.day.from_now
      )

      expect { user.destroy! }.to change(described_class, :count).by(-1)
        .and change(EmailVerificationToken, :count).by(-1)

      expect(EmailVerificationToken.exists?(token.id)).to be(false)
    end

    it "destroys all favorites and carts for the user" do
      user = create(:user)
      first_favorite = Favorite.create!(user: user, guest_token: SecureRandom.hex(24), expires_at: 1.day.from_now)
      second_favorite = Favorite.create!(user: user, guest_token: SecureRandom.hex(24), expires_at: 1.day.from_now)
      first_cart = Cart.create!(user: user, guest_token: SecureRandom.hex(24), expires_at: 1.day.from_now)
      second_cart = Cart.create!(user: user, guest_token: SecureRandom.hex(24), expires_at: 1.day.from_now)

      expect { user.destroy! }.to change(described_class, :count).by(-1)
        .and change(Favorite, :count).by(-2)
        .and change(Cart, :count).by(-2)

      expect(Favorite.where(id: [first_favorite.id, second_favorite.id])).to be_empty
      expect(Cart.where(id: [first_cart.id, second_cart.id])).to be_empty
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
