# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebpayReturnUrl do
  describe '.normalize' do
    it 'rewrites storefront /payment/success to API handler' do
      result = described_class.normalize(
        'https://ikeya.by/payment/success',
        api_base: 'https://ikeya.by'
      )
      expect(result).to eq('https://ikeya.by/api/v1/payment/success')
    end

    it 'keeps explicit API return URL' do
      url = 'https://ikeya.by/api/v1/payment/success'
      expect(described_class.normalize(url, api_base: 'https://ikeya.by')).to eq(url)
    end
  end
end
