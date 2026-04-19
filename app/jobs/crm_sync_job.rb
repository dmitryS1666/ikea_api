class CrmSyncJob < ApplicationJob
  queue_as :default

  def perform(entity_type, entity_id, action = 'sync')
    case entity_type
    when 'User'
      user = User.find_by(id: entity_id)
      return unless user
      CrmIntegrationService.sync_user(user)
    when 'Order'
      order = Order.find_by(id: entity_id)
      return unless order
      CrmIntegrationService.sync_order(order)
    when 'ReturnRequest'
      req = ReturnRequest.find_by(id: entity_id)
      return unless req
      CrmIntegrationService.notify_return(req)
    when 'CooperationRequest'
      req = CooperationRequest.find_by(id: entity_id)
      return unless req
      CrmIntegrationService.notify_cooperation(req)
    end
  rescue => e
    Rails.logger.error "[CrmSyncJob] Failed for #{entity_type} #{entity_id}: #{e.message}"
    raise e # Re-raise for Sidekiq/ActiveJob retry
  end
end
