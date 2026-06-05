require 'rails_helper'

RSpec.describe EuropostCreateShipmentJob, type: :job do
  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:user) do
    create(
      :user,
      first_name: 'Иван',
      last_name: 'Иванов',
      middle_name: 'Иванович',
      phone: '375291234567',
      email: 'ivan@example.com'
    )
  end

  let(:product) do
    create(
      :product,
      weight: 2.5,
      package_volume: nil,
      package_dimensions: '10 x 20 x 30 cm',
      dimensions: nil,
      full_attributes: {}
    )
  end

  before do
    allow(CalculatorSetting).to receive(:get).and_call_original
    allow(CalculatorSetting).to receive(:get).with('europost_max_weight_kg').and_return(30.0)
    allow(CalculatorSetting).to receive(:get).with('europost_max_volume_m3').and_return(0.25)
    allow(CalculatorSetting).to receive(:get).with('europost_max_dimension_cm').and_return(105.0)
    allow(CalculatorSetting).to receive(:get).with('europost_max_dimensions_sum_cm').and_return(180.0)
    allow(CalculatorSetting).to receive(:get).with('europost_max_side_dimensions_cm').and_return(nil)
    allow(ReindexProductFiltersJob).to receive(:perform_later)
    allow(UpdateOrderTrackingInfoJob).to receive(:perform_later)
    allow(CrmSyncJob).to receive(:perform_later)
  end

  it 'creates Europost shipment and stores received track number on the order' do
    order = create(
      :order,
      user: user,
      status: :paid,
      delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
      payment_order_number: 'PAY-1001',
      total_amount: 123.45,
      full_name: 'Иванов Иван Иванович',
      phone: '+375 (29) 123-45-67',
      address_json: {
        'pickup_point_id' => 70130090,
        'delivery' => {
          'pickup_point' => {
            'external_id' => '70130090'
          }
        }
      }
    )
    create(:order_item, order: order, product_sku: product.sku, quantity: 2, price: 10)

    allow(EuropostApiService).to receive(:postal_create).and_return(
      'number' => 'BY080027046773',
      'status' => { 'name' => 'Заявка создана', 'value' => 0 },
      'full_price' => 9.99
    )

    with_env(
      'EUROPOST_STORE_ID_START' => '70130090',
      'EUROPOST_CONTRACTOR_UNN' => '193323100',
      'EUROPOST_API_TOKEN' => 'token'
    ) do
      described_class.perform_now(order.id)
    end

    order.reload
    expect(order.track_number).to eq('BY080027046773')
    expect(order.tracking_info.dig('europost_create', 'status')).to eq('created')
    expect(order.tracking_info.dig('europost_create', 'track_number')).to eq('BY080027046773')
    expect(EuropostApiService).to have_received(:postal_create)
  end
end
