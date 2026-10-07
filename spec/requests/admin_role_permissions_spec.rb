# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin role permissions", type: :request do
  def login_as(user, password: "password")
    post "/admin/login", params: { user: { username: user.username, password: password } }
    expect(response).to have_http_status(:redirect)
  end

  def full_permission_params(overrides = {})
    base = User::ADMIN_PERMISSION_KEYS.index_with { "0" }
    overrides.each { |key, value| base[key] = value }
    base.transform_keys { |key| :"permission_#{key}" }
  end

  let!(:owner) { create(:user, role: "admin", username: "director_rbac", is_active: true) }
  let!(:observer_role) do
    AdminRolePermission.ensure_defaults!
    AdminRolePermission.find_by!(role: "observer")
  end

  it "lets the owner open role cards and toggle permission checkboxes" do
    login_as(owner)

    get "/admin/admin_role_permissions"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(observer_role.role_label)

    get "/admin/admin_role_permissions/#{observer_role.id}/edit"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(User.permission_label(:orders_read))
    expect(response.body).to include("permission_orders_read")

    patch "/admin/admin_role_permissions/#{observer_role.id}", params: {
      admin_role_permission: full_permission_params(
        reports_view: "1",
        content_read: "1",
        requests_read: "1"
      )
    }

    expect(response).to redirect_to("/admin/admin_role_permissions/#{observer_role.id}/edit")
    observer_role.reload
    expect(observer_role.permissions_hash[:orders_read]).to be(false)
    expect(observer_role.permissions_hash[:reports_view]).to be(true)
    expect(observer_role.permissions_hash[:content_read]).to be(true)

    observer = create(:user, role: "observer", is_active: true)
    expect(observer.has_admin_permission?(:orders_read)).to be(false)
    expect(observer.has_admin_permission?(:content_read)).to be(true)
  end

  it "forbids roles without restrictions_manage" do
    manager = create(:user, role: "manager_requests", username: "mgr_rbac", is_active: true)

    open_session do |session|
      session.post "/admin/login", params: { user: { username: manager.username, password: "password" } }
      expect(session.response).to have_http_status(:redirect)

      session.get "/admin/admin_role_permissions"
      expect(session.response).to have_http_status(:redirect)
      expect(session.response.body).not_to include("Права ролей")
    end
  end
end
