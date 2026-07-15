# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :admin_user, :request_id, :ip_address
end
