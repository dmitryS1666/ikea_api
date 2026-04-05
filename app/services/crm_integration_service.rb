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

  def self.log_request(method, url, options)
    Rails.logger.info "[AmoCRM Request] #{method.upcase} #{url}"
    headers = options[:headers] || {}
    Rails.logger.info "[AmoCRM Headers] #{headers.inspect}"
    Rails.logger.info "[AmoCRM Body] #{options[:body].inspect}"
    Rails.logger.info "[AmoCRM Query] #{options[:query].inspect}" if options[:query]
  end

  def self.post_with_log(url, options = {})
    log_request('post', url, options)
    post(url, options)
  end

  def self.patch_with_log(url, options = {})
    log_request('patch', url, options)
    patch(url, options)
  end

  def self.get_with_log(url, options = {})
    log_request('get', url, options)
    get(url, options)
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

    response = post_with_log(url, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
    
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

    response = post_with_log(url, body: payload.to_json, headers: { 'Content-Type' => 'application/json' })
    
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

    custom_fields = [
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
        field_id: contact_field_id('COUNTRY'),
        values: [{ value: user.country_code.to_s }]
      }
    ]

    # Добавляем телефон и email в правильном формате для multitext полей
    if user.phone.present?
      custom_fields << {
        field_id: contact_field_id('PHONE'),
        values: [{ value: user.phone, enum_code: 'MOB' }]
      }
    end

    if user.email.present?
      custom_fields << {
        field_id: contact_field_id('EMAIL'),
        values: [{ value: user.email, enum_code: 'WORK' }]
      }
    end

    payload = {
      name: user.username.presence || user.email || user.phone,
      custom_fields_values: custom_fields
    }

    response = if contact_id
      patch_with_log("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
    else
      post_with_log("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
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
          values: [{ value: Time.current.strftime("%d.%m.%Y %H:%M:%S") }]
        }
      ]
    }
    patch_with_log("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
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

    response = post_with_log("#{base_url}/api/v4/tasks", body: [task_payload].to_json, headers: headers)
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

    # Подготовка списка товаров для поля
    items_text = order.order_items.map { |oi| "#{oi.product_sku} x #{oi.quantity}" }.join("\n")

    # 2. Создаем сделку (Lead)
    full_name_parts = order.full_name.to_s.split(' ')
    first_name = full_name_parts[0] || order.user.username || "—"
    last_name = full_name_parts[1..-1].join(' ').presence || "—"
    
    form_data_text = [
      "Имя - #{first_name}",
      "Фамилия - #{last_name}",
      "Телефон - #{order.phone || order.user.phone}",
      "Сумма - #{order.total_amount} BYN",
      "Метод оплаты - #{order.payment_method}",
      "Метод доставки - #{order.delivery_type}"
    ]

    if order.address_json.present?
      form_data_text << "Адрес - #{order.address_json.values.join(', ')}"
    end

    lead_payload = {
      name: "Заказ №#{order.id} от #{order.full_name}",
      price: order.total_amount.to_i,
      status_id: Order.statuses[order.status],
      pipeline_id: 10700202,
      custom_fields_values: [
        {
          field_id: contact_field_id('FORM_NAME'),
          values: [{ value: 'Оформление заказа' }]
        },
        {
          field_id: contact_field_id('FORM_DATA'),
          values: [{ value: form_data_text.join("\n") }]
        },
        {
          field_id: contact_field_id('PAYMENT_METHOD'),
          values: [{ value: order.payment_method }]
        },
        {
          field_id: contact_field_id('ORDER_NUMBER'),
          values: [{ value: order.id.to_s }]
        },
        {
          field_id: contact_field_id('ORDER_DATE'),
          values: [{ value: order.created_at.to_i }]
        },
        {
          field_id: contact_field_id('ITEMS_LIST'),
          values: [{ value: items_text }]
        }
      ],
      _embedded: {
        contacts: [{ id: contact_id }]
      }
    }

    # Добавляем адрес, если есть
    if order.address_json.present?
      address_text = order.address_json.values.join(", ")
      lead_payload[:custom_fields_values] << {
        field_id: contact_field_id('ADDRESS'),
        values: [{ value: address_text }]
      }
    end

    # Маппинг типа доставки в select поле AmoCRM
    delivery_enum_id = case order.delivery_type
    when 'courier' then 831835 # Courier
    when 'pickup'  then 831831 # Evropost
    else nil
    end

    if delivery_enum_id
      lead_payload[:custom_fields_values] << {
        field_id: contact_field_id('DELIVERY_TYPE'),
        values: [{ enum_id: delivery_enum_id }]
      }
    end

    response = post_with_log("#{base_url}/api/v4/leads", body: [lead_payload].to_json, headers: headers)
    
    if response.success?
      lead_id = response.parsed_response.dig('_embedded', 'leads', 0, 'id')
      order.update_columns(crm_external_id: lead_id) if lead_id
      
      # 3. Синхронизируем товары через примечания (дополнительно)
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
    response = get_with_log("#{base_url}/api/v4/contacts", query: { query: query }, headers: headers)
    Rails.logger.info "[AmoCRM] Find contact response: #{response.code}"
    return :error if response.code >= 500
    return nil unless response.success? && response.parsed_response.present?

    response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
  end

  def self.create_contact(payload)
    Rails.logger.info "[AmoCRM] Creating contact: #{payload.inspect}"
    response = post_with_log("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    Rails.logger.info "[AmoCRM] Create contact response: #{response.code}"
    response.success?
  end

  def self.update_contact(contact_id, payload)
    response = patch_with_log("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
    response.success?
  end

  def self.create_contact_with_id(payload)
    response = post_with_log("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
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
    post_with_log("#{base_url}/api/v4/leads/#{lead_id}/notes", body: [note_payload].to_json, headers: headers)
  end

  def self.contact_field_id(code)
    mapping = {
      'PHONE' => 145813,
      'EMAIL' => 145815,
      'GDPR_CONSENT' => 150883,
      'EXTERNAL_ID' => 151485,
      'NEWSLETTER_CONSENT' => 578785,
      'VERIFIED' => 578787,
      'COUNTRY' => 578899,
      'LAST_LOGIN' => 578901,
      'PAYMENT_METHOD' => 573935,
      'DELIVERY_TYPE' => 578791,
      'ORDER_NUMBER' => 578801,
      'ORDER_DATE' => 578799,
      'ITEMS_LIST' => 578789,
      'ADDRESS' => 578793,
      'FORM_NAME' => 579201,
      'FORM_DATA' => 579191
    }
    mapping[code] || code
  end
end
