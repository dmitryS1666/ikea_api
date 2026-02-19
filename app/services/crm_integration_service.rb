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

  def self.exchange_code_for_tokens(code)
    url = "#{base_url}/oauth2/access_token"
    payload = {
      client_id: ENV['AMO_CRM_CLIENT_ID'],
      client_secret: ENV['AMO_CRM_CLIENT_SECRET'],
      grant_type: 'authorization_code',
      code: code,
      redirect_uri: ENV['AMO_CRM_REDIRECT_URI'] || 'https://localhost'
    }

    response = post(url, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
    
    if response.success?
      tokens = response.parsed_response
      Rails.logger.info "[AmoCRM] Tokens received successfully"
      { success: true, tokens: tokens }
    else
      Rails.logger.error "[AmoCRM] Token exchange failed: #{response.body}"
      { success: false, error: response.body, code: response.code }
    end
  end

  def self.refresh_access_token(refresh_token)
    url = "#{base_url}/oauth2/access_token"
    payload = {
      client_id: ENV['AMO_CRM_CLIENT_ID'],
      client_secret: ENV['AMO_CRM_CLIENT_SECRET'],
      grant_type: 'refresh_token',
      refresh_token: refresh_token,
      redirect_uri: ENV['AMO_CRM_REDIRECT_URI'] || 'https://localhost'
    }

    response = post(url, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
    
    if response.success?
      { success: true, tokens: response.parsed_response }
    else
      Rails.logger.error "[AmoCRM] Token refresh failed: #{response.body}"
      { success: false, error: response.body, code: response.code }
    end
  end

  def self.sync_user(user)
    # Поиск контакта по телефону или email
    contact_id = find_contact(user)
    
    # Если find_contact вернул :error, значит была ошибка API
    return { success: false, error: "API Error during contact search" } if contact_id == :error

    payload = {
      name: user.username || user.email,
      custom_fields_values: [
        {
          field_id: contact_field_id('COUNTRY'),
          values: [{ value: user.country_code }]
        },
        {
          field_id: contact_field_id('GDPR_CONSENT'),
          values: [{ value: user.gdpr_consent }]
        },
        {
          field_id: contact_field_id('NEWSLETTER_CONSENT'),
          values: [{ value: user.newsletter_consent }]
        },
        {
          field_id: contact_field_id('EXTERNAL_ID'),
          values: [{ value: user.id.to_s }]
        },
        {
          field_id: contact_field_id('REGISTRATION_DATE'),
          values: [{ value: user.created_at.to_i }]
        }
      ].compact
    }

    response = if contact_id
      patch("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
    else
      # Добавляем телефон и email при создании
      payload[:custom_fields_values] << {
        field_id: contact_field_id('PHONE'),
        values: [{ value: user.phone }]
      } if user.phone.present?
      
      payload[:custom_fields_values] << {
        field_id: contact_field_id('EMAIL'),
        values: [{ value: user.email }]
      } if user.email.present?

      post("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    end

    if response.success?
      { success: true, data: response.parsed_response }
    else
      { success: false, error: response.body, code: response.code }
    end
  rescue => e
    Rails.logger.error "[AmoCRM] Sync user failed: #{e.message}"
    { success: false, error: e.message }
  end

  def self.update_last_login(user)
    contact_id = find_contact(user)
    return unless contact_id && contact_id != :error

    payload = {
      custom_fields_values: [
        {
          field_id: contact_field_id('LAST_LOGIN'),
          values: [{ value: Time.current.to_i }]
        }
      ]
    }
    patch("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
  end

  def self.notify_return(return_request)
    # Создание задачи или сделки на возврат
    Rails.logger.info "[AmoCRM] Notifying about return request #{return_request.id}"
    
    # Поиск контакта
    contact_id = find_contact(return_request.order.user)
    return false unless contact_id && contact_id != :error

    task_payload = {
      entity_id: contact_id,
      entity_type: 'contacts',
      text: "Запрос на возврат по заказу ##{return_request.order_id}. Причина: #{return_request.reason}",
      complete_till: 1.day.from_now.to_i,
      task_type_id: 1 # Обычно 1 - это "Связаться с клиентом"
    }

    response = post("#{base_url}/api/v4/tasks", body: [task_payload].to_json, headers: headers)
    response.success?
  end

  def self.sync_order(order)
    # 1. Сначала убеждаемся, что контакт есть в CRM
    contact_id = find_contact(order.user)
    if contact_id == :error
      return { success: false, error: "Contact search failed" }
    end

    unless contact_id
      contact_payload = {
        name: order.full_name.presence || order.user.username || order.user.email
      }
      contact_id = create_contact_with_id(contact_payload)
    end

    return { success: false, error: "Could not create or find contact" } unless contact_id

    # 2. Создаем сделку (Lead)
    lead_payload = {
      name: "Заказ №#{order.id} от #{order.full_name}",
      price: order.total_amount.to_i,
      custom_fields_values: [
        {
          field_id: contact_field_id('PAYMENT_METHOD'),
          values: [{ value: order.payment_method }]
        },
        {
          field_id: contact_field_id('DELIVERY_TYPE'),
          values: [{ value: order.delivery_type }]
        }
      ],
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
      { success: true, lead_id: lead_id }
    else
      Rails.logger.error "[AmoCRM] Sync order #{order.id} failed: #{response.body}"
      { success: false, error: response.body, code: response.code }
    end
  rescue => e
    Rails.logger.error "[AmoCRM] Sync order #{order.id} exception: #{e.message}"
    { success: false, error: e.message }
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
