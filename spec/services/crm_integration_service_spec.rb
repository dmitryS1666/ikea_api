require 'rails_helper'

RSpec.describe CrmIntegrationService do
  let(:user) { create(:user, username: 'Test User', email: 'test@example.com', phone: '+375291234567', role: 'user') }
  let(:base_url) { "https://testsub.amocrm.ru" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AMO_CRM_SUBDOMAIN').and_return('testsub')
    allow(ENV).to receive(:[]).with('AMO_CRM_ACCESS_TOKEN').and_return('testtoken')
    
    WebMock.reset!
  end

  describe '.sync_user' do
    it 'creates a new contact when not found' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 204, body: '')
      
      stub_request(:post, %r{#{base_url}/api/v4/contacts})
        .to_return(status: 200, body: [{ id: 123 }].to_json, headers: { 'Content-Type' => 'application/json' })

      expect(described_class.sync_user(user)).to be_truthy
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

      expect(described_class.sync_user(user)).to be_truthy
      expect(WebMock).to have_requested(:patch, "#{base_url}/api/v4/contacts/456")
    end

    it 'returns false on API error during find' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 500)
      
      expect(described_class.sync_user(user)).to be_falsey
    end

    it 'returns false on API error during create' do
      stub_request(:get, %r{#{base_url}/api/v4/contacts}).to_return(status: 204, body: '')
      stub_request(:post, %r{#{base_url}/api/v4/contacts}).to_return(status: 500)
      
      expect(described_class.sync_user(user)).to be_falsey
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

      expect(described_class.sync_order(order)).to be_truthy
      expect(order.reload.crm_external_id).to eq('789')
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads")
      expect(WebMock).to have_requested(:post, "#{base_url}/api/v4/leads/789/notes")
    end

    it 'returns false if lead creation fails' do
      stub_request(:post, %r{#{base_url}/api/v4/leads}).to_return(status: 500)

      expect(described_class.sync_order(order)).to be_falsey
    end
  end
end
