class ExchangeRate < ApplicationRecord
  # После сбоя НБРБ не дергаем API повторно из request path.
  API_FAILURE_TTL = 30.minutes
  FETCH_MUTEXES = Concurrent::Map.new
  API_FAILURES = Concurrent::Map.new

  validates :date, presence: true
  validates :currency_code, presence: true
  validates :rate, presence: true, numericality: { greater_than: 0 }
  validates :scale, presence: true, numericality: { greater_than: 0 }
  validates :currency_code, uniqueness: { scope: :date }

  # Получить курс за 1 единицу валюты
  def rate_per_unit
    rate / scale.to_f
  end

  # Получить актуальный курс валюты
  # @param currency_code [String] Код валюты
  # @param date [Date, nil] Дата (по умолчанию сегодня)
  # @return [ExchangeRate, nil]
  def self.current(currency_code, date = nil)
    date ||= Date.current
    where(currency_code: currency_code.to_s.upcase, date: date).first
  end

  # Последний известный курс на дату или раньше.
  def self.latest_on_or_before(currency_code, date = nil)
    date ||= Date.current
    where(currency_code: currency_code.to_s.upcase)
      .where(arel_table[:date].lteq(date))
      .order(date: :desc)
      .first
  end

  # Получить или создать курс из API НБ РБ.
  # Защита от деградации API/DNS:
  # - короткий таймаут на стороне NbrbApiService
  # - mutex на валюту+дату (один поток ходит в API)
  # - circuit breaker на 30 минут после сбоя
  # - fallback на последний курс из БД и запись его на сегодня
  #
  # @param currency_code [String] Код валюты
  # @param date [Date, nil] Дата
  # @return [ExchangeRate, nil]
  def self.fetch_or_create(currency_code, date = nil)
    date = (date || Date.current).to_date
    code = currency_code.to_s.upcase

    existing = current(code, date)
    return existing if existing

    mutex_for(code, date).synchronize do
      existing = current(code, date)
      return existing if existing

      if should_call_api?(code, date)
        rate_data = NbrbApiService.get_rate(code, date)
        if rate_data
          clear_api_failure!(code, date)
          created = persist_from_api!(rate_data, requested_date: date)
          return created if created
        else
          mark_api_failure!(code, date)
          Rails.logger.warn(
            "ExchangeRate: NBRB unavailable for #{code} on #{date}, using DB fallback"
          )
        end
      else
        Rails.logger.info(
          "ExchangeRate: skipping NBRB for #{code} on #{date} (circuit open), using DB fallback"
        )
      end

      fallback_rate(code, date)
    end
  end

  def self.mutex_for(code, date)
    FETCH_MUTEXES.compute_if_absent("#{code}:#{date}") { Mutex.new }
  end
  private_class_method :mutex_for

  def self.should_call_api?(code, date)
    key = "#{code}:#{date}"
    failure_at = API_FAILURES[key]

    if failure_at.present? && Time.current - failure_at < API_FAILURE_TTL
      return false
    end

    if Rails.cache.read(api_failure_cache_key(code, date))
      API_FAILURES[key] ||= Time.current
      return false
    end

    clear_api_failure!(code, date) if failure_at.present?
    true
  end
  private_class_method :should_call_api?

  def self.mark_api_failure!(code, date)
    API_FAILURES["#{code}:#{date}"] = Time.current
    Rails.cache.write(api_failure_cache_key(code, date), true, expires_in: API_FAILURE_TTL)
  rescue StandardError => e
    Rails.logger.warn("ExchangeRate: failed to write API failure cache: #{e.message}")
  end
  private_class_method :mark_api_failure!

  def self.clear_api_failure!(code, date)
    API_FAILURES.delete("#{code}:#{date}")
    Rails.cache.delete(api_failure_cache_key(code, date))
  rescue StandardError => e
    Rails.logger.warn("ExchangeRate: failed to clear API failure cache: #{e.message}")
  end
  private_class_method :clear_api_failure!

  def self.api_failure_cache_key(code, date)
    "exchange_rate/nbrb_fail/#{code}/#{date}"
  end
  private_class_method :api_failure_cache_key

  def self.persist_from_api!(rate_data, requested_date:)
    persist_date = rate_data[:date].presence || requested_date
    code = rate_data[:currency_code]

    record = create!(
      date: persist_date,
      currency_code: code,
      rate: rate_data[:rate],
      official_rate: rate_data[:rate],
      scale: rate_data[:scale]
    )

    # Если НБРБ вернул курс с другой датой (выходной), продублируем на запрошенную.
    if persist_date != requested_date && current(code, requested_date).nil?
      copy_as!(record, requested_date)
    else
      record
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    current(code, requested_date) || current(code, persist_date)
  end
  private_class_method :persist_from_api!

  def self.fallback_rate(code, date)
    previous = latest_on_or_before(code, date)
    return nil unless previous

    # Для сегодняшнего дня фиксируем fallback в БД, чтобы request path больше не ходил в API.
    if date == Date.current && previous.date != date
      copy_as!(previous, date)
    else
      previous
    end
  end
  private_class_method :fallback_rate

  def self.copy_as!(source, date)
    create!(
      date: date,
      currency_code: source.currency_code,
      rate: source.rate,
      official_rate: source.official_rate.presence || source.rate,
      scale: source.scale
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    current(source.currency_code, date) || source
  end
  private_class_method :copy_as!
end
