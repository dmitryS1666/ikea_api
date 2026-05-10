require "securerandom"

class LegalPage < ApplicationRecord
  enum status: { draft: 0, published: 1, disabled: 2 }

  SEED_PAGES = [
    ["personal-data-consent-ikeya-by", "СОГЛАСИЕ НА ОБРАБОТКУ ПЕРСОНАЛЬНЫХ ДАННЫХ IKEYA.BY"],
    ["public-offer-commission-ikeya", "ПУБЛИЧНАЯ ОФЕРТА (ДОГОВОР КОМИССИИ) IKEYA"],
    ["referral-technologies-rules-ikeya-by", "ПРАВИЛА ПРИМЕНЕНИЯ РЕКОМЕНДАТЕЛЬНЫХ ТЕХНОЛОГИЙ IKEYA.BY"],
    ["customs-payments-rules", "ПРАВИЛА ОПЛАТЫ ТАМОЖЕННЫХ ПЛАТЕЖЕЙ"],
    ["content-and-materials-usage-rules-ikeya-by", "ПРАВИЛА ИСПОЛЬЗОВАНИЯ КОНТЕНТА И МАТЕРИАЛОВ IKEYA.BY"],
    ["user-agreement-ikeya-service", "ПОЛЬЗОВАТЕЛЬСКОЕ СОГЛАШЕНИЕ СЕРВИСА IKEYA"],
    ["privacy-policy-clients-ikeya-by", "ПОЛИТИКА ОБРАБОТКИ ПЕРСОНАЛЬНЫХ ДАННЫХ КЛИЕНТОВ IKEYA.BY"],
    ["cookie-policy-ikeya-by", "ПОЛИТИКА В ОТНОШЕНИИ ФАЙЛОВ COOKIE IKEYA.BY"],
    ["webpay-services-payment-ikeya-by", "ОПЛАТА УСЛУГ (СЕРВИС WebPay) IKEAYA.BY"],
    ["delivery-international-logistics-ikeya-by", "ДОСТАВКА (INTERNATIONAL LOGISTICS) IKEYA.BY"],
    ["customs-broker-agreement", "ДОГОВОР С ТАМОЖЕННЫМ БРОКЕРОМ"],
    ["returns-and-exchange-ikeya-by", "ВОЗВРАТ И ОБМЕН ТОВАРОВ  IKEYA.BY"]
  ].freeze

  validates :title, :slug, presence: true
  validates :slug, uniqueness: true

  before_validation :normalize_slug

  scope :for_public_api, -> { published.order(:id) }

  def self.seed_defaults!
    SEED_PAGES.each_with_index do |(slug, title), index|
      record = find_or_initialize_by(slug: slug)
      next unless record.new_record?

      record.title = title
      record.position = index
      record.status = :draft
      record.save!
    end
  end

  private

  def normalize_slug
    return if title.blank? && slug.present?

    base_slug = slug.present? ? slug : title
    normalized_base = normalize_slug_candidate(base_slug)
    normalized_base = "legal-page-#{SecureRandom.hex(4)}" if normalized_base.blank?
    candidate = normalized_base

    counter = 2
    while LegalPage.where.not(id: id).exists?(slug: candidate)
      candidate = "#{normalized_base}-#{counter}"
      counter += 1
    end

    self.slug = candidate
  end

  def normalize_slug_candidate(value)
    value.to_s.parameterize
  end
end
