class CrmIntegrationService
  def self.sync_user(user)
    # Заглушка передачи данных в CRM
    Rails.logger.info "Syncing user #{user.id} to CRM with country #{user.country_code}"
    # Здесь настраиваются поля и проверяются права доступа в CRM
    true
  end

  def self.notify_return(return_request)
    # Заглушка уведомления менеджера в CRM о возврате
    Rails.logger.info "Notifying CRM about return request #{return_request.id}"
    true
  end
end
