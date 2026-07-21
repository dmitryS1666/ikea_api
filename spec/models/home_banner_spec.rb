require 'rails_helper'

RSpec.describe HomeBanner, type: :model do
  describe 'section/variant mapping' do
    it 'maps horizontal variants and breakpoints' do
      banner = described_class.new(
        section: :horizontal,
        variant: :horizontal_960x256,
        position: 1,
        slot_key: 'horizontal-beds-1',
        custom_url: '/catalog/beds',
        active: true
      )
      banner.valid?
      expect(banner.breakpoint).to eq('tablet')
      expect(banner.expected_dimensions).to eq([960, 256])
    end

    it 'rejects variant that does not match section' do
      banner = described_class.new(
        section: :main,
        variant: :horizontal_1500x256,
        position: 1,
        slot_key: 'main-1',
        custom_url: '/x',
        active: true
      )
      expect(banner).not_to be_valid
      expect(banner.errors[:variant]).to be_present
    end

    it 'requires category or custom_url' do
      banner = described_class.new(
        section: :advertising,
        variant: :advertising_742x256,
        position: 1,
        slot_key: 'adv-1',
        active: true
      )
      expect(banner).not_to be_valid
      expect(banner.errors[:base].join).to include('категорию или кастомную ссылку')
    end
  end

  describe '.secondary' do
    it 'aliases horizontal section' do
      expect(described_class.secondary.to_sql).to include('"section" = 1')
    end
  end
end
