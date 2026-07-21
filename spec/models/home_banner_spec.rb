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

    it 'maps advertising desktop to 742×256' do
      banner = described_class.new(
        section: :advertising,
        variant: :advertising_742x256,
        position: 1,
        slot_key: 'ads-1',
        custom_url: '/promo',
        active: true
      )
      banner.valid?
      expect(banner.breakpoint).to eq('desktop')
      expect(banner.expected_dimensions).to eq([742, 256])
    end

    it 'maps advertising tablet and mobile to 960×256' do
      tablet = described_class.new(
        section: :advertising,
        variant: :advertising_960x256,
        position: 1,
        slot_key: 'ads-1',
        custom_url: '/promo',
        active: true
      )
      tablet.valid?
      expect(tablet.breakpoint).to eq('tablet')
      expect(tablet.expected_dimensions).to eq([960, 256])

      mobile = described_class.new(
        section: :advertising,
        variant: :advertising_mobile_960x256,
        position: 1,
        slot_key: 'ads-1',
        custom_url: '/promo',
        active: true
      )
      mobile.valid?
      expect(mobile.breakpoint).to eq('mobile')
      expect(mobile.expected_dimensions).to eq([960, 256])
    end

    it 'allows all three advertising responsive variants' do
      expect(described_class::SECTION_VARIANTS['advertising'].keys).to contain_exactly('desktop', 'tablet', 'mobile')
      expect(described_class::SECTION_VARIANTS['advertising'].values).to contain_exactly(
        'advertising_742x256',
        'advertising_960x256',
        'advertising_mobile_960x256'
      )
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

    it 'keeps an explicit position change on update for an existing slot' do
      sibling = described_class.new(
        section: :main,
        variant: :main_1500x516,
        position: 1,
        slot_key: 'main-test-slot',
        custom_url: '/a',
        active: false
      )
      sibling.save!(validate: false)

      banner = described_class.new(
        section: :main,
        variant: :main_960x516,
        position: 1,
        slot_key: 'main-test-slot',
        custom_url: '/a',
        active: false
      )
      banner.save!(validate: false)

      banner.position = 4
      banner.valid?
      expect(banner.position).to eq(4)
    ensure
      described_class.where(slot_key: 'main-test-slot').delete_all
    end
  end

  describe '.secondary' do
    it 'aliases horizontal section' do
      expect(described_class.secondary.to_sql).to include('"section" = 1')
    end
  end
end
