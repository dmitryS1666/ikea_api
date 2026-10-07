# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::StaffParamGuard do
  def controller_for(user:, resource:, payload:, action: "update")
    params = ActionController::Parameters.new(resource.singularize => payload)
    admin = Struct.new(:name).new(resource)
    Struct.new(:current_user, :admin, :action_name, :params).new(user, admin, action, params)
  end

  it "keeps only the status when a request manager updates an order" do
    user = build(:user, role: "manager_requests", is_active: true)
    controller = controller_for(
      user: user,
      resource: "orders",
      payload: { "status" => "processing", "phone" => "+375291112233", "full_name" => "Иван", "total_amount" => "10" }
    )

    described_class.apply(controller)

    expect(controller.params["order"].to_unsafe_h).to eq("status" => "processing")
  end

  it "does not let a site admin blank a phone" do
    user = build(:user, role: "site_admin", is_active: true)
    controller = controller_for(
      user: user,
      resource: "orders",
      payload: { "status" => "processing", "phone" => "" }
    )

    described_class.apply(controller)

    expect(controller.params["order"].key?("phone")).to be(false)
    expect(controller.params["order"]["status"]).to eq("processing")
  end

  it "strips passport fields from everyone except the owner" do
    user = build(:user, role: "super_admin", is_active: true)
    controller = controller_for(
      user: user,
      resource: "users",
      payload: { "first_name" => "Анна", "passport_verified_at" => Time.current.iso8601 }
    )

    described_class.apply(controller)

    expect(controller.params["user"].key?("passport_verified_at")).to be(false)
    expect(controller.params["user"]["first_name"]).to eq("Анна")
  end

  it "does not let the owner submit the super_admin role" do
    user = build(:user, role: "admin", is_active: true)
    controller = controller_for(
      user: user,
      resource: "users",
      payload: { "role" => "super_admin", "first_name" => "Анна" }
    )

    described_class.apply(controller)

    expect(controller.params["user"].key?("role")).to be(false)
  end
end
