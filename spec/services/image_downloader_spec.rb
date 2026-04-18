# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImageDownloader do
  describe '.normalize_remote_image_url (private helper)' do
    it 'нормализует protocol-relative URL' do
      url = '//www.ikea.com/globalassets/foo.jpg'
      expect(described_class.send(:normalize_remote_image_url, url)).to eq('https://www.ikea.com/globalassets/foo.jpg')
    end

    it 'нормализует относительный путь без схемы' do
      url = '/globalassets/foo.jpg'
      expect(described_class.send(:normalize_remote_image_url, url)).to eq('https://www.ikea.com/globalassets/foo.jpg')
    end

    it 'убирает только query-параметр pvid, остальные параметры сохраняет' do
      url = 'https://www.ikea.com/foo.jpg?pvid=123&f=webp#frag'
      expect(described_class.send(:normalize_remote_image_url, url)).to eq('https://www.ikea.com/foo.jpg?f=webp')
    end

    it 'не отбрасывает URL, где pvid встречается только в пути' do
      url = 'https://www.ikea.com/pvid/foo.jpg'
      expect(described_class.send(:normalize_remote_image_url, url)).to eq('https://www.ikea.com/pvid/foo.jpg')
    end
  end
end
