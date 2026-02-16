class CrmIntegrationService
  include HTTParty
  
  def self.base_url
    "https://#{ENV['AMO_CRM_SUBDOMAIN']}.amocrm.ru"
  end

  def self.headers
    {
      'Authorization' => "Bearer #{ENV['AMO_CRM_ACCESS_TOKEN']}",
      'Content-Type' => 'application/json'
    }
  end

  def self.sync_user(user)
    # Поиск контакта по телефону или email
    contact_id = find_contact(user)
    
    # Если find_contact вернул :error, значит была ошибка API
    return false if contact_id == :error

    payload = {
      name: user.username || user.email,
      custom_fields_values: [
        {
          field_id: 'PHONE',
          values: [{ value: user.phone }]
        },
        {
          field_id: 'EMAIL',
          values: [{ value: user.email }]
        }
      ]
    }

    if contact_id
      update_contact(contact_id, payload)
    else
      create_contact(payload)
    end
  rescue => e
    Rails.logger.error "[AmoCRM] Sync user failed: #{e.message}"
    # Rails.logger.error e.backtrace.join("\n")
    false
  end

  def self.notify_return(return_request)
    # Создание задачи или сделки на возврат
    Rails.logger.info "[AmoCRM] Notifying about return request #{return_request.id}"
    # В реальной реализации здесь будет создание сделки в воронке "Возвраты"
    true
  end

  def self.sync_order(order)
    # 1. Сначала убеждаемся, что контакт есть в CRM
    contact_id = find_contact(order.user)
    if contact_id == :error
      Rails.logger.error "[AmoCRM] Sync order #{order.id} failed: contact find error"
      return false
    end

    unless contact_id
      contact_payload = {
        name: order.full_name.presence || order.user.username || order.user.email,
        custom_fields_values: [
          { field_id: 'PHONE', values: [{ value: order.phone || order.user.phone }] },
          { field_id: 'EMAIL', values: [{ value: order.user.email }] }
        ]
      }
      contact_id = create_contact_with_id(contact_payload)
    end

    return false unless contact_id

    # 2. Создаем сделку (Lead)
    lead_payload = {
      name: "Заказ №#{order.id} от #{order.full_name}",
      price: order.total_amount.to_i,
      _embedded: {
        contacts: [{ id: contact_id }]
      }
    }

    response = post("#{base_url}/api/v4/leads", body: [lead_payload].to_json, headers: headers)
    
    if response.success?
      lead_id = response.parsed_response.dig('_embedded', 'leads', 0, 'id')
      order.update_columns(crm_external_id: lead_id) if lead_id
      
      # 3. Синхронизируем товары через примечания
      sync_order_items(lead_id, order) if lead_id
      true
    else
      Rails.logger.error "[AmoCRM] Sync order #{order.id} failed: #{response.body}"
      false
    end
  rescue => e
    Rails.logger.error "[AmoCRM] Sync order #{order.id} exception: #{e.message}"
    false
  end

  private

  def self.find_contact(user)
    query = user.phone.presence || user.email
    return nil if query.blank?

    Rails.logger.info "[AmoCRM] Finding contact for #{query}"
    response = get("#{base_url}/api/v4/contacts", query: { query: query }, headers: headers)
    Rails.logger.info "[AmoCRM] Find contact response: #{response.code}"
    return :error if response.code >= 500
    return nil unless response.success? && response.parsed_response.present?

    response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
  end

  def self.create_contact(payload)
    Rails.logger.info "[AmoCRM] Creating contact: #{payload.inspect}"
    response = post("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    Rails.logger.info "[AmoCRM] Create contact response: #{response.code}"
    response.success?
  end

  def self.update_contact(contact_id, payload)
    response = patch("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
    response.success?
  end

  def self.create_contact_with_id(payload)
    response = post("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    return nil unless response.success?
    response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
  end

  def self.sync_order_items(lead_id, order)
    items_text = order.order_items.map { |oi| "#{oi.product_sku} x #{oi.quantity}" }.join("\n")
    note_payload = {
      entity_id: lead_id,
      note_type: 'common',
      params: {
        text: "Состав заказа:\n#{items_text}"
      }
    }
    post("#{base_url}/api/v4/leads/#{lead_id}/notes", body: [note_payload].to_json, headers: headers)
  end

  def self.contact_field_id(code)
    # В AmoCRM системные ID полей могут отличаться, обычно это:
    # PHONE: 'PHONE', EMAIL: 'EMAIL' в API v4 можно использовать коды
    code
  end
end
