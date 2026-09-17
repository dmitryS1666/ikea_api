require 'rails_helper'

RSpec.describe CrmIntegrationService do
  let(:user) { create(:user, username: 'Test User', email: 'test@example.com', phone: '+375291234567', role: 'user') }
  let(:base_url) { "https://shopbyshop.amocrm.ru" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AMO_CRM_SUBDOMAIN').and_return('shopbyshop')
    allow(ENV).to receive(:[]).with('AMO_CRM_ACCESS_TOKEN').and_return('testtoken')
    
    # Disable CRM sync callbacks during tests to avoid unexpected requests
    allow_any_instance_of(User).to receive(:sync_with_crm).and_return(true)
    allow_any_instance_of(Order).to receive(:sync_with_crm).and_return(true)
    
    WebMock.reset!
  end

  describe '.sync_user' do
    it 'creates a new contact when not found' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 204, body: '')
      
      stub_request(:post, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 200, body: { _embedded: { contacts: [{ id: 123 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.sync_user(user)
      expect(result[:success]).to be_truthy
      expect(user.reload.crm_contact_id).to eq('123')
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/contacts")
    end

    it 'updates existing contact when found' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts})
        .with(query: { query: user.phone })
        .to_return(
          status: 200,
          body: { _embedded: { contacts: [{ id: 456 }] } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      stub_request(:patch, %r{#{base_url}/api/v4/contacts/456})
        .to_return(status: 200, body: { id: 456 }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.sync_user(user)
      expect(result[:success]).to be_truthy
      expect(user.reload.crm_contact_id).to eq('456')
      expect(WebMock).to have_requested(:patch, "#{base_url}/api/v4/contacts/456")
    end

    it 'returns error status on API error during find' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 500)
      
      result = described_class.sync_user(user)
      expect(result[:success]).to be_falsey
      expect(result[:error]).to eq("API Error during contact search")
    end

    it 'returns error status on API error during create' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 204, body: '')
      stub_request(:post, %r{#{base_url}/api/v4/contacts}).to_return(status: 500)
      
      result = described_class.sync_user(user)
      expect(result[:success]).to be_falsey
    end
  end

  describe '.sync_order' do
    let(:order) { create(:order, user: user, total_amount: 1000, full_name: 'John Doe', phone: '+375291112233') }
    let!(:order_item) { create(:order_item, order: order, product_sku: 'SKU123', quantity: 2) }

    before do
      # Mock finding contact
      stub_request(:get, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 200, body: { _embedded: { contacts: [{ id: 123 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates a lead in AmoCRM' do
      stub_request(:post, %r{#{base_url}/api/v4/leads})
        .to_return(status: 200, body: { _embedded: { leads: [{ id: 789 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
      
      stub_request(:post, %r{#{base_url}/api/v4/leads/789/notes})
        .to_return(status: 200, body: {}.to_json)

      result = described_class.sync_order(order)
      expect(result[:success]).to be_truthy
      expect(order.reload.crm_external_id).to eq('789')
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads")
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads/789/notes")
    end

    it 'updates existing lead in AmoCRM' do
      order.update_columns(crm_external_id: '789')
      
      stub_request(:patch, %r{#{base_url}/api/v4/leads/789})
        .to_return(status: 200, body: { id: 789 }.to_json, headers: { 'Content-Type' => 'application/json' })
      
      stub_request(:post, %r{#{base_url}/api/v4/leads/789/notes})
        .to_return(status: 200, body: {}.to_json)

      result = described_class.sync_order(order)
      expect(result[:success]).to be_truthy
      expect(WebMock).to have_requested(:patch, "#{base_url}/api/v4/leads/789")
    end

    it 'returns error status if lead creation fails' do
      stub_request(:post, %r{#{base_url}/api/v4/leads}).to_return(status: 500)

      result = described_class.sync_order(order)
      expect(result[:success]).to be_falsey
    end

    it 'sends stored string crm_contact_id as integer' do
      user.update_columns(crm_contact_id: '42583661')

      stub_request(:post, "#{base_url}/api/v4/leads")
        .to_return(status: 200, body: { _embedded: { leads: [{ id: 789 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, "#{base_url}/api/v4/leads/789/notes")
        .to_return(status: 200, body: {}.to_json)

      result = described_class.sync_order(order)

      expect(result[:success]).to be_truthy
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads").with { |request|
        lead = JSON.parse(request.body).first
        lead.dig('_embedded', 'contacts', 0, 'id') == 42_583_661
      }
      expect(WebMock).not_to have_requested(:get, %r{#{base_url}/api/v4/contacts})
    end

    it 'sends note entity_id as integer when crm_external_id is a string' do
      user.update_columns(crm_contact_id: '42583661')
      order.update_columns(crm_external_id: '789')

      stub_request(:patch, "#{base_url}/api/v4/leads/789")
        .to_return(status: 200, body: { id: 789 }.to_json, headers: { 'Content-Type' => 'application/json' })
      notes = stub_request(:post, "#{base_url}/api/v4/leads/789/notes")
        .to_return(status: 200, body: {}.to_json)

      described_class.sync_order(order)

      expect(notes).to have_been_requested
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads/789/notes").with { |request|
        JSON.parse(request.body).first['entity_id'] == 789
      }
    end

    it 'sends order number as public_uid and formatted items list' do
      product = create(
        :product,
        sku: 'SKU123',
        name_ru: 'Мягкая развивающая книжка, Занятые строители, синяя',
        cached_slug: 'soft-activity-book-busy-builders-sebra-play-blue',
        url: '/products/soft-activity-book-busy-builders-sebra-play-blue'
      )
      order_item.update!(product: product, price: 71.26, quantity: 1)

      leads_request = stub_request(:post, "#{base_url}/api/v4/leads")
        .to_return(status: 200, body: { _embedded: { leads: [{ id: 789 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, "#{base_url}/api/v4/leads/789/notes")
        .to_return(status: 200, body: {}.to_json)

      result = described_class.sync_order(order)

      expect(result[:success]).to be_truthy
      expect(leads_request).to have_been_requested

      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads").with { |request|
        lead_payload = JSON.parse(request.body).first
        order_number_field = lead_payload.fetch('custom_fields_values').find { |f| f['field_id'] == 578801 }
        items_field = lead_payload.fetch('custom_fields_values').find { |f| f['field_id'] == 578789 }
        items_text = items_field.dig('values', 0, 'value')

        lead_payload['name'] == order.public_uid &&
          order_number_field.dig('values', 0, 'value') == order.public_uid &&
          items_text.include?("1. Мягкая развивающая книжка, Занятые строители, синяя (SKU123) x1 ----- 71.26 PLN") &&
          items_text.include?(product.url)
      }
    end
  end

  describe '.amo_entity_id' do
    it 'coerces numeric strings and keeps integers' do
      expect(described_class.amo_entity_id('42583661')).to eq(42_583_661)
      expect(described_class.amo_entity_id(789)).to eq(789)
      expect(described_class.amo_entity_id(nil)).to be_nil
      expect(described_class.amo_entity_id('')).to be_nil
      expect(described_class.amo_entity_id(:error)).to eq(:error)
    end
  end

  describe '.resync_missing_orders' do
    it 'resyncs only non-draft orders without crm_external_id' do
      missing = create(:order, user: user, checkout_draft: false)
      create(:order, user: user, checkout_draft: false, crm_external_id: '111')
      create(:order, user: user, checkout_draft: true)

      allow(described_class).to receive(:sync_order).and_return({ success: true, lead_id: 999 })

      results = described_class.resync_missing_orders

      expect(results.map { |row| row[:order_id] }).to eq([missing.id])
      expect(described_class).to have_received(:sync_order).with(missing).once
    end
  end

  describe '.update_last_login' do
    before { user.update_columns(crm_contact_id: '456') }

    it 'patches LAST_LOGIN custom field on the contact' do
      freeze_time do
        stub_request(:patch, "#{base_url}/api/v4/contacts/456")
          .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

        described_class.update_last_login(user)

        expect(WebMock).to have_requested(:patch, "#{base_url}/api/v4/contacts/456").with { |request|
          payload = JSON.parse(request.body)
          field = payload.fetch('custom_fields_values').find { |f| f['field_id'] == 578_901 }
          field.dig('values', 0, 'value') == Time.current.strftime('%d.%m.%Y %H:%M:%S')
        }
      end
    end

    it 'does nothing when contact id is missing' do
      user.update_columns(crm_contact_id: nil)
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 204, body: '')

      described_class.update_last_login(user)

      expect(WebMock).not_to have_requested(:patch, %r{#{base_url}/api/v4/contacts})
    end
  end

  describe '.notify_return' do
    let(:order) { create(:order, user: user, total_amount: 500) }
    let(:return_request) do
      build(:return_request, order: order, user: user, compensation_type: 'refund', reason: 'damaged').tap do |req|
        allow(CrmSyncJob).to receive(:perform_later)
        req.save!
      end
    end

    before do
      user.update_columns(crm_contact_id: '123')
      stub_request(:post, %r{#{base_url}/api/v4/leads})
        .to_return(status: 200, body: { _embedded: { leads: [{ id: 555 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates a return lead linked to the contact' do
      expect(described_class.notify_return(return_request)).to be(true)

      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads").with { |request|
        lead = JSON.parse(request.body).first
        lead['name'].include?('Возврат') &&
          lead.dig('_embedded', 'contacts', 0, 'id') == 123 &&
          lead.fetch('custom_fields_values').any? { |f| f['field_id'] == 578_807 }
      }
    end

    it 'returns false when contact cannot be resolved' do
      user.update_columns(crm_contact_id: nil)
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 500)

      expect(described_class.notify_return(return_request)).to be(false)
    end
  end

  describe '.notify_cooperation' do
    before do
      stub_request(:get, %r{#{base_url}/api/v4/contacts})
        .to_return(
          status: 200,
          body: { _embedded: { contacts: [] } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
      stub_request(:post, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 200, body: { _embedded: { contacts: [{ id: 777 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, %r{#{base_url}/api/v4/leads})
        .to_return(status: 200, body: { _embedded: { leads: [{ id: 888 }] } }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'creates a cooperation lead with applicant data' do
      cooperation_request = build(:cooperation_request)
      allow(CrmSyncJob).to receive(:perform_later)
      cooperation_request.save!

      expect(described_class.notify_cooperation(cooperation_request)).to be(true)

      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads").with { |request|
        lead = JSON.parse(request.body).first
        lead['name'].include?(cooperation_request.full_name) &&
          lead.dig('_embedded', 'contacts', 0, 'id') == 777 &&
          lead.dig('_embedded', 'contacts', 0, 'id').is_a?(Integer)
      }
    end
  end
end
