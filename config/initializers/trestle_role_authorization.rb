# frozen_string_literal: true

require "trestle/resource/toolbar"
require "trestle/table/actions_column"

# Trestle builds its toolbars independently from controller authorization.
# Keep buttons consistent with the same RBAC rule that protects direct URLs.
module TrestleRoleToolbarAuthorization
  protected

  def action?(action)
    return false unless super

    user = @template.try(:current_user)
    return true unless user

    user.allowed_for_admin_resource?(admin.name, action)
  end
end

module TrestleRoleTableActions
  def default_actions
    lambda do |toolbar, _instance, admin|
      if admin&.actions&.include?(:destroy) &&
         current_user&.allowed_for_admin_resource?(admin.name, :destroy)
        toolbar.delete
      end
    end
  end
end

Trestle::Resource::Toolbar::Builder.prepend(TrestleRoleToolbarAuthorization)
Trestle::Table::ActionsColumn.prepend(TrestleRoleTableActions)
