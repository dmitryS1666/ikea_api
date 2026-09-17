class CrmSyncJob < ApplicationJob
  queue_as :default

  def perform(entity_type, entity_id, action = 'sync')
    case entity_type
    when 'User'
      user = User.find_by(id: entity_id)
      return unless user
      ensure_sync_success!('User', entity_id, CrmIntegrationService.sync_user(user))
    when 'Order'
      order = Order.find_by(id: entity_id)
      return unless order
      return if order.checkout_draft?
      ensure_sync_success!('Order', entity_id, CrmIntegrationService.sync_order(order))
    when 'ReturnRequest'
      req = ReturnRequest.find_by(id: entity_id)
      return unless req
      ensure_sync_success!('ReturnRequest', entity_id, CrmIntegrationService.notify_return(req))
    when 'CooperationRequest'
      req = CooperationRequest.find_by(id: entity_id)
      return unless req
      ensure_sync_success!('CooperationRequest', entity_id, CrmIntegrationService.notify_cooperation(req))
    end
  rescue => e
    Rails.logger.error "[CrmSyncJob] Failed for #{entity_type} #{entity_id}: #{e.message}"
    raise e # Re-raise for Sidekiq/ActiveJob retry
  end

  private

  def ensure_sync_success!(entity_type, entity_id, result)
    return if result == true
    return if result.is_a?(Hash) && result[:success]

    detail = result.is_a?(Hash) ? (result[:error].presence || result[:code]) : result.inspect
    raise CrmIntegrationService::Error, "#{entity_type} #{entity_id} sync failed: #{detail}"
  end
end
