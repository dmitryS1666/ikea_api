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
    contact_id = user.crm_contact_id || find_contact(user)
    return { success: false, error: "API Error during contact search" } if contact_id == :error

    custom_fields = [
      {
        field_id: contact_field_id('GDPR_CONSENT'),
        values: [{ value: user.gdpr_consent }]
      },
      {
        field_id: contact_field_id('NEWSLETTER_CONSENT_EMAIL'),
        values: [{ value: user.newsletter_consent || user.email_marketing }]
      },
      {
        field_id: contact_field_id('NEWSLETTER_CONSENT_TG'),
        values: [{ value: user.telegram_marketing }]
      },
      {
        field_id: contact_field_id('VERIFIED'),
        values: [{ value: user.passport_verified? }]
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

    if (passport = user.passport_data).present?
      [
        ['PASSPORT_SERIES', passport['series']],
        ['PASSPORT_NUMBER', passport['number']],
        ['PASSPORT_ISSUED_DATE', passport['issued_date']],
        ['PASSPORT_ISSUED_BY', passport['issued_by']],
        ['PASSPORT_ID_NUMBER', passport['id_number']],
        ['DOB', user.dob&.strftime("%d.%m.%Y")]
      ].each do |code, value|
        next if value.blank?
        custom_fields << {
          field_id: contact_field_id(code),
          values: [{ value: value }]
        }
      end
    end

    if user.middle_name.present?
      custom_fields << {
        field_id: contact_field_id('MIDDLE_NAME'),
        values: [{ value: user.middle_name }]
      }
    end

    payload = {
      name: user.full_name.presence || user.username.presence || user.email || user.phone,
      first_name: user.first_name,
      last_name: user.last_name,
      custom_fields_values: custom_fields
    }

    response = if contact_id
      patch_with_log("#{base_url}/api/v4/contacts/#{contact_id}", body: payload.to_json, headers: headers)
    else
      post_with_log("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    end

    if response.success?
      if !user.crm_contact_id
        new_contact_id = contact_id || response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
        user.update_columns(crm_contact_id: new_contact_id) if new_contact_id
      end
      { success: true, data: response.parsed_response }
    else
      { success: false, error: response.body, code: response.code }
    end
  rescue => e
    Rails.logger.error "[AmoCRM] Sync user failed: #{e.message}"
    { success: false, error: e.message }
  end

  def self.update_last_login(user)
    contact_id = user.crm_contact_id || find_contact(user)
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
    Rails.logger.info "[AmoCRM] Notifying about return request #{return_request.id}"

    user = return_request.user
    contact_id =
      if user
        user.crm_contact_id || find_contact(user)
      else
        find_or_create_contact_for_return(return_request)
      end
    return false unless contact_id && contact_id != :error

    status_id = case return_request.status
                when 'new' then 83327814
                when 'in_review' then 83327818
                when 'approved' then 142
                when 'rejected' then 143
                else 83327814
                end

    fio = return_request.applicant_full_name.presence || user&.full_name
    phone = return_request.phone.presence || user&.phone
    email = return_request.email.presence || user&.email
    order_label = return_request.order_number.presence || return_request.order_id.to_s
    return_type_label =
      case return_request.compensation_type
      when 'exchange' then 'Обмен'
      else 'Возврат'
      end

    lead_payload = {
      name: "Возврат по заказу №#{order_label}",
      price: return_request.order.total_amount.to_i,
      status_id: status_id,
      custom_fields_values: [
        { field_id: contact_field_id('RETURN_FIO'), values: [{ value: fio }] },
        { field_id: contact_field_id('RETURN_ORDER_ID'), values: [{ value: order_label }] },
        { field_id: contact_field_id('RETURN_PHONE'), values: [{ value: phone }] },
        { field_id: contact_field_id('RETURN_EMAIL'), values: [{ value: email }] },
        { field_id: contact_field_id('RETURN_REASON'), values: [{ value: return_request.reason }] },
        { field_id: contact_field_id('RETURN_COMMENT'), values: [{ value: return_request.comment }] },
        { field_id: contact_field_id('RETURN_TYPE'), values: [{ value: return_type_label }] },
        { field_id: contact_field_id('RETURN_DATE'), values: [{ value: return_request.created_at.to_i }] }
      ].reject { |f| f.dig(:values, 0, :value).blank? },
      _embedded: {
        contacts: [{ id: contact_id }]
      }
    }

    if return_request.attachments.attached?
      begin
        urls = return_request.attachments.map { |a| Rails.application.routes.url_helpers.rails_blob_url(a, host: ENV['HOST_URL'] || 'https://localhost') }
        lead_payload[:custom_fields_values] << {
          field_id: contact_field_id('RETURN_FILES'),
          values: [{ value: urls.join("\n") }]
        }
      rescue => e
        Rails.logger.warn "[AmoCRM] Could not generate attachment URLs: #{e.message}"
      end
    end

    response = post_with_log("#{base_url}/api/v4/leads", body: [lead_payload].to_json, headers: headers)
    response.success?
  end

  def self.notify_cooperation(cooperation_request)
    Rails.logger.info "[AmoCRM] Notifying about cooperation request #{cooperation_request.id}"

    contact_id = find_or_create_contact_for_cooperation(cooperation_request)
    return false unless contact_id && contact_id != :error

    pipeline_id = ENV['AMO_CRM_COOP_PIPELINE_ID']&.to_i
    status_id = (ENV['AMO_CRM_COOP_STATUS_ID']&.to_i).presence

    lead_payload = {
      name: "Сотрудничество: #{cooperation_request.full_name}",
      custom_fields_values: [
        { field_id: contact_field_id('COOP_TYPE'), values: [{ value: cooperation_request.cooperation_type }] },
        { field_id: contact_field_id('COOP_COMPANY'), values: [{ value: cooperation_request.company }] },
        { field_id: contact_field_id('COOP_CITY'), values: [{ value: cooperation_request.city }] },
        { field_id: contact_field_id('COOP_COMMENT'), values: [{ value: cooperation_request.comment }] },
        { field_id: contact_field_id('COOP_PD_CONSENT'), values: [{ value: cooperation_request.personal_data_consent }] },
        { field_id: contact_field_id('COOP_EMAIL_CONSENT'), values: [{ value: cooperation_request.marketing_email_consent }] }
      ].reject { |f| f.dig(:values, 0, :value).blank? },
      _embedded: { contacts: [{ id: contact_id }] }
    }

    lead_payload[:pipeline_id] = pipeline_id if pipeline_id.present? && pipeline_id.positive?
    lead_payload[:status_id] = status_id if status_id.present? && status_id.positive?

    response = post_with_log("#{base_url}/api/v4/leads", body: [lead_payload].to_json, headers: headers)
    response.success?
  rescue => e
    Rails.logger.error "[AmoCRM] Notify cooperation failed: #{e.message}"
    false
  end

  def self.sync_order(order)
    contact_id = order.user.crm_contact_id || find_contact(order.user)
    if contact_id == :error
      return { success: false, error: "Contact search failed" }
    end

    unless contact_id
      contact_payload = {
        name: order.full_name.presence || order.user.username || order.user.email,
        first_name: order.user.first_name,
        last_name: order.user.last_name
      }
      contact_id = create_contact_with_id(contact_payload)
      order.user.update_columns(crm_contact_id: contact_id) if contact_id
    end

    return { success: false, error: "Could not create or find contact" } unless contact_id

    items_text = format_order_items_for_amo(order)
    order_number = order.public_uid.presence || order.id.to_s

    lead_payload = {
      name: order_number,
      price: order.total_amount.to_i,
      status_id: Order.statuses[order.status],
      pipeline_id: 10700202,
      custom_fields_values: [
        {
          field_id: contact_field_id('PAYMENT_STATUS'),
          values: [{ value: order.paid? }]
        },
        {
          field_id: contact_field_id('PAYMENT_METHOD'),
          values: [{ value: order.payment_method }]
        },
        {
          field_id: contact_field_id('ORDER_NUMBER'),
          values: [{ value: order_number }]
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

    if (address_text = order.address_json.values.join(", ")).present?
      lead_payload[:custom_fields_values] << {
        field_id: contact_field_id('ADDRESS'),
        values: [{ value: address_text }]
      }
    end

    normalized_delivery_type = DeliveryTypeNormalizer.normalize(order.delivery_type)

    delivery_enum_id = case normalized_delivery_type
    when 'belpost'   then 831829
    when 'evropost'  then 831831
    when 'europost_pickup' then 831831
    when 'courier'   then 831835
    when 'ikeya_delivery' then 831835
    else nil
    end

    if delivery_enum_id
      lead_payload[:custom_fields_values] << {
        field_id: contact_field_id('DELIVERY_TYPE'),
        values: [{ enum_id: delivery_enum_id }]
      }
    end

    if (services = order.address_json['services']).present?
      lead_payload[:custom_fields_values] << {
        field_id: contact_field_id('SERVICES'),
        values: [{ value: OrderServicesFormatter.labels_joined(services) }]
      }
    end

    response = if order.crm_external_id.present?
      patch_with_log("#{base_url}/api/v4/leads/#{order.crm_external_id}", body: lead_payload.to_json, headers: headers)
    else
      post_with_log("#{base_url}/api/v4/leads", body: [lead_payload].to_json, headers: headers)
    end
    
    if response.success?
      lead_id = order.crm_external_id || response.parsed_response.dig('_embedded', 'leads', 0, 'id')
      order.update_columns(crm_external_id: lead_id) if lead_id && order.crm_external_id.blank?
      
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
    return :error if response.code >= 500
    return nil unless response.success? && response.parsed_response.present?

    response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
  end

  def self.create_contact_with_id(payload)
    response = post_with_log("#{base_url}/api/v4/contacts", body: [payload].to_json, headers: headers)
    return nil unless response.success?
    response.parsed_response.dig('_embedded', 'contacts', 0, 'id')
  end

  def self.find_or_create_contact_for_return(return_request)
    query = return_request.phone.presence || return_request.email

    if query.present?
      Rails.logger.info "[AmoCRM] Finding contact for return #{query}"
      response = get_with_log("#{base_url}/api/v4/contacts", query: { query: query }, headers: headers)
      return :error if response.code >= 500
      found = response.success? ? response.parsed_response.dig('_embedded', 'contacts', 0, 'id') : nil
      return found if found.present?
    end

    contact_payload = {
      name: return_request.applicant_full_name.presence || "Возврат ##{return_request.id}",
      first_name: return_request.first_name,
      custom_fields_values: []
    }

    if return_request.phone.present?
      contact_payload[:custom_fields_values] << {
        field_id: contact_field_id('PHONE'),
        values: [{ value: return_request.phone, enum_code: 'MOB' }]
      }
    end

    if return_request.email.present?
      contact_payload[:custom_fields_values] << {
        field_id: contact_field_id('EMAIL'),
        values: [{ value: return_request.email, enum_code: 'WORK' }]
      }
    end

    create_contact_with_id(contact_payload)
  end

  def self.find_or_create_contact_for_cooperation(cooperation_request)
    query = cooperation_request.phone.presence || cooperation_request.email

    if query.present?
      Rails.logger.info "[AmoCRM] Finding contact for cooperation #{query}"
      response = get_with_log("#{base_url}/api/v4/contacts", query: { query: query }, headers: headers)
      return :error if response.code >= 500
      found = response.success? ? response.parsed_response.dig('_embedded', 'contacts', 0, 'id') : nil
      return found if found.present?
    end

    contact_payload = {
      name: cooperation_request.full_name,
      first_name: cooperation_request.first_name,
      last_name: cooperation_request.last_name,
      custom_fields_values: []
    }

    if cooperation_request.phone.present?
      contact_payload[:custom_fields_values] << {
        field_id: contact_field_id('PHONE'),
        values: [{ value: cooperation_request.phone, enum_code: 'MOB' }]
      }
    end

    if cooperation_request.email.present?
      contact_payload[:custom_fields_values] << {
        field_id: contact_field_id('EMAIL'),
        values: [{ value: cooperation_request.email, enum_code: 'WORK' }]
      }
    end

    create_contact_with_id(contact_payload)
  end

  def self.sync_order_items(lead_id, order)
    items_text = format_order_items_for_amo(order)
    note_payload = {
      entity_id: lead_id,
      note_type: 'common',
      params: { text: "Состав заказа:\n#{items_text}" }
    }
    post_with_log("#{base_url}/api/v4/leads/#{lead_id}/notes", body: [note_payload].to_json, headers: headers)
  end

  def self.format_order_items_for_amo(order)
    return "" if order.order_items.blank?

    rows = order.order_items.each_with_index.map do |order_item, index|
      title = order_item.product&.name_ru.presence || order_item.product&.name.presence || "Товар"
      sku = order_item.product_sku.to_s
      quantity = order_item.quantity.to_i
      unit_price = Kernel.format("%.2f", order_item.price.to_f)

      line = "#{index + 1}. #{title} (#{sku}) x#{quantity} ----- #{unit_price} PLN"
      product_url = amo_product_url(order_item)
      product_url.present? ? "#{line}\n#{product_url}" : line
    end

    rows.join("\n-----------------------------------\n")
  end

  def self.amo_product_url(order_item)
    product = order_item.product
    return nil unless product

    raw_url = product.url.to_s.strip
    return nil if raw_url.blank?

    host = ENV["HOST_URL"].to_s.strip
    host = "https://ikeay.by" if host.blank?
    host = host.sub(%r{/\z}, "")

    return raw_url if raw_url.match?(/\Ahttps?:\/\//i)

    path = raw_url.start_with?("/") ? raw_url : "/#{raw_url}"
    "#{host}#{path}"
  end

  def self.contact_field_id(code)
    mapping = {
      'PHONE' => 145813,
      'EMAIL' => 145815,
      'GDPR_CONSENT' => 150883,
      'EXTERNAL_ID' => 151485,
      'NEWSLETTER_CONSENT_EMAIL' => 578785,
      'NEWSLETTER_CONSENT_TG' => 578783,
      'VERIFIED' => 578787,
      'COUNTRY' => 578899,
      'LAST_LOGIN' => 578901,
      'PAYMENT_METHOD' => 573935,
      'PAYMENT_STATUS' => 578797,
      'DELIVERY_TYPE' => 578791,
      'ORDER_NUMBER' => 578801,
      'ORDER_DATE' => 578799,
      'ITEMS_LIST' => 578789,
      'SERVICES' => 578795,
      'ADDRESS' => 578793,
      'MIDDLE_NAME' => 579213, # Поле "Отчетсов" из ТЗ
      'PASSPORT_SERIES' => 579201, # В ТЗ нет явного маппинга, использую свободные ID или из кода
      'PASSPORT_NUMBER' => 579203,
      'PASSPORT_ISSUED_DATE' => 579205,
      'PASSPORT_ISSUED_BY' => 579207,
      'PASSPORT_ID_NUMBER' => 579209,
      'DOB' => 579211,
      'RETURN_FIO' => 578817,
      'RETURN_ORDER_ID' => 578801,
      'RETURN_PHONE' => 578803,
      'RETURN_EMAIL' => 578805,
      'RETURN_REASON' => 578807,
      'RETURN_COMMENT' => 578809,
      'RETURN_FILES' => 578811,
      'RETURN_TYPE' => 578813,
      'RETURN_DATE' => 578815,
      'COOP_COMPANY' => ENV['AMO_CRM_COOP_COMPANY_FIELD_ID']&.to_i,
      'COOP_CITY' => ENV['AMO_CRM_COOP_CITY_FIELD_ID']&.to_i,
      'COOP_TYPE' => ENV['AMO_CRM_COOP_TYPE_FIELD_ID']&.to_i,
      'COOP_COMMENT' => ENV['AMO_CRM_COOP_COMMENT_FIELD_ID']&.to_i,
      'COOP_PD_CONSENT' => ENV['AMO_CRM_COOP_PD_CONSENT_FIELD_ID']&.to_i,
      'COOP_EMAIL_CONSENT' => ENV['AMO_CRM_COOP_EMAIL_CONSENT_FIELD_ID']&.to_i,
      'WEIGHT' => 363323,
      'TRACK_NUMBER' => 377661,
      'CANCELLATION_REASON' => 578819
    }
    mapping[code].presence || code
  end
end
