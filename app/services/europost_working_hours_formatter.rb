# frozen_string_literal: true

# Builds human-readable working_hours and optional structured fields for Europost pickup points.
# - `working_hours` string: режим на сегодня (по iso_day_of_week в schedules), иначе агрегат API / legacy.
# - `schedules`: строки только за текущую календарную неделю (пн–вс), плюс weekday_short (пн … вск).
class EuropostWorkingHoursFormatter
  WEEKDAY_SHORT_RU = {
    1 => "пн",
    2 => "вт",
    3 => "ср",
    4 => "чт",
    5 => "пт",
    6 => "сб",
    7 => "вск"
  }.freeze

  DAY_LABEL_PATTERN = /\A(\d{1,2})[.\s-]+([а-яё]+)/i.freeze

  RU_MONTH_TO_NUMBER = {
    "янв" => 1, "января" => 1, "январь" => 1,
    "фев" => 2, "февраля" => 2, "февраль" => 2,
    "мар" => 3, "марта" => 3, "март" => 3,
    "апр" => 4, "апреля" => 4, "апрель" => 4,
    "май" => 5, "мая" => 5,
    "июн" => 6, "июня" => 6, "июнь" => 6,
    "июл" => 7, "июля" => 7, "июль" => 7,
    "авг" => 8, "августа" => 8, "август" => 8,
    "сен" => 9, "сент" => 9, "сентября" => 9, "сентябрь" => 9,
    "окт" => 10, "октября" => 10, "октябрь" => 10,
    "ноя" => 11, "нояб" => 11, "ноября" => 11, "ноябрь" => 11,
    "дек" => 12, "декабря" => 12, "декабрь" => 12
  }.freeze

  def self.display_working_hours_entries(office)
    schedules = normalized_schedules(office)
    return schedules if schedules.any?

    wh = office["working_hours"].to_s.strip
    bh = office["break_hours"].to_s.strip
    if wh.present?
      return [{ "work_time" => wh, "lunch_time" => bh.presence }.compact]
    end

    legacy = legacy_info_entries(office)
    return legacy if legacy.any?

    nil
  end

  def self.summary_for_payload(office)
    today_line = summary_line_from_today_schedule(office)
    return today_line if today_line.present?

    raw_schedules = office["schedules"] || office[:schedules]
    if raw_schedules.is_a?(Array) && raw_schedules.any?
      return api_aggregate_hours_string(office).presence || legacy_info_text(office).presence
    end

    entries = display_working_hours_entries(office)
    if entries.nil?
      return legacy_info_text(office).presence
    end

    text = entries.map { |e| format_entry(e) }.reject(&:blank?).join("; ").strip
    text.presence
  end

  def self.structured_for_payload(office)
    raw_schedules = office["schedules"] || office[:schedules]
    br = office["break"].presence || office[:break].presence
    br ||= office["breaks"].presence || office[:breaks].presence
    bh = office["break_hours"].presence || office[:break_hours].presence

    out = {}
    week_schedules = schedules_for_current_week(raw_schedules)
    out[:schedules] = week_schedules if week_schedules.any?
    out[:break_hours] = bh if bh.present?
    if br.is_a?(Hash)
      out[:break] = br
    elsif br.is_a?(Array)
      out[:breaks] = br
    end
    wh = (office["working_hours"] || office[:working_hours]).to_s.strip
    out[:working_hours] = wh if wh.present?
    out
  end

  def self.normalized_schedules(office)
    raw = office["schedules"] || office[:schedules]
    schedules_for_current_week(raw)
  end
  private_class_method :normalized_schedules

  def self.schedules_for_current_week(raw)
    return [] unless raw.is_a?(Array)

    entries = raw.select { |s| schedule_entry_usable?(s) }
    return [] if entries.empty?

    week_start, week_end = current_week_bounds

    (1..7).filter_map do |iso|
      target_date = week_start + (iso - 1)
      entry = pick_entry_for_week_day(entries, target_date, iso, week_start, week_end)
      next unless entry

      enrich_schedule_row(entry, calendar_iso: iso)
    end
  end
  private_class_method :schedules_for_current_week

  def self.schedule_entry_usable?(entry)
    return false unless entry.is_a?(Hash)

    entry["work_time"].present? || entry[:work_time].present? ||
      entry["is_working"].present? || entry[:is_working].present?
  end
  private_class_method :schedule_entry_usable?

  def self.pick_entry_for_week_day(entries, target_date, iso, week_start, week_end)
    iso_fallback = nil

    entries.each do |entry|
      parsed = schedule_row_date(entry, week_start, week_end)
      if parsed == target_date
        return entry
      end

      if parsed
        next unless parsed.between?(week_start, week_end)
        next
      end

      iso_fallback = entry if iso_fallback.nil? && schedule_row_iso(entry) == iso
    end

    iso_fallback
  end
  private_class_method :pick_entry_for_week_day

  def self.schedule_row_iso(entry)
    (entry["iso_day_of_week"].presence || entry[:iso_day_of_week].presence).to_i
  end
  private_class_method :schedule_row_iso

  def self.current_week_bounds(reference = reference_date)
    start = reference.beginning_of_week(:monday)
    [start, start + 6.days]
  end
  private_class_method :current_week_bounds

  def self.schedule_row_date(entry, week_start, week_end)
    reference = week_start + 3.days

    %w[date schedule_date day_date].each do |key|
      raw = entry[key].presence || entry[key.to_sym].presence
      next if raw.blank?

      parsed = parse_schedule_date_value(raw, reference: reference)
      return parsed if parsed
    end

    day_label = entry["day"].presence || entry[:day].presence
    parse_day_label(day_label, reference: reference)
  end
  private_class_method :schedule_row_date

  def self.parse_schedule_date_value(raw, reference:)
    if raw.is_a?(Date)
      return raw
    end

    if raw.is_a?(Time) || raw.is_a?(DateTime) || raw.is_a?(ActiveSupport::TimeWithZone)
      return raw.to_date
    end

    s = raw.to_s.strip
    return nil if s.blank?

    Date.iso8601(s)
  rescue ArgumentError
    parse_day_label(s, reference: reference)
  end
  private_class_method :parse_schedule_date_value

  def self.parse_day_label(label, reference: reference_date)
    s = label.to_s.strip
    return nil if s.blank?

    m = s.match(DAY_LABEL_PATTERN)
    return nil unless m

    day = m[1].to_i
    month_key = m[2].downcase.delete_suffix(".")
    month = RU_MONTH_TO_NUMBER[month_key] || RU_MONTH_TO_NUMBER[month_key[0, 3]]
    return nil unless month

    year = reference.year
    candidate = Date.new(year, month, day)
    adjust_parsed_day_year(candidate, reference)
  rescue ArgumentError
    nil
  end
  private_class_method :parse_day_label

  def self.adjust_parsed_day_year(candidate, reference)
    return candidate if (candidate - reference).abs <= 183

    if candidate > reference
      Date.new(reference.year - 1, candidate.month, candidate.day)
    else
      Date.new(reference.year + 1, candidate.month, candidate.day)
    end
  rescue ArgumentError
    candidate
  end
  private_class_method :adjust_parsed_day_year

  def self.format_entry(entry)
    return "" unless entry.is_a?(Hash)

    wt = entry["work_time"].presence || entry[:work_time].presence
    lt = entry["lunch_time"].presence || entry[:lunch_time].presence
    parts = [wt, lt].compact
    parts.join(", ")
  end
  private_class_method :format_entry

  def self.legacy_info_entries(office)
    info_texts = legacy_info_texts(office)
    return [] if info_texts.empty?

    if info_texts.any? { |text| text.match?(/режим\s*работы|hours|time/i) }
      [{ "work_time" => info_texts.find { |t| t.match?(/режим\s*работы|hours|time/i) }, "lunch_time" => nil }.compact]
    else
      [{ "work_time" => info_texts.first, "lunch_time" => nil }.compact]
    end
  end
  private_class_method :legacy_info_entries

  def self.legacy_info_text(office)
    legacy_info_texts(office).find { |text| text.match?(/режим\s*работы|hours|time/i) } ||
      legacy_info_texts(office).first
  end
  private_class_method :legacy_info_text

  def self.legacy_info_texts(office)
    [office["Info1"], office["Info2"], office["Info3"]]
      .map { |value| value.to_s.strip }
      .reject(&:blank?)
  end
  private_class_method :legacy_info_texts

  def self.reference_date
    Time.zone&.today || Date.today
  end
  private_class_method :reference_date

  def self.today_cwday
    reference_date.cwday
  end
  private_class_method :today_cwday

  def self.summary_line_from_today_schedule(office)
    raw = office["schedules"] || office[:schedules]
    return nil unless raw.is_a?(Array)

    week_schedules = schedules_for_current_week(raw)
    return nil if week_schedules.empty?

    today = reference_date
    row = week_schedules.find { |s| schedule_row_date(s, *current_week_bounds(today)) == today }
    row ||= week_schedules.find { |s| schedule_row_matches_iso_day?(s, today_cwday) }
    return nil unless row.is_a?(Hash)

    format_entry(row).presence
  end
  private_class_method :summary_line_from_today_schedule

  def self.schedule_row_matches_iso_day?(entry, iso_cwday)
    return false unless entry.is_a?(Hash)

    iso = entry["iso_day_of_week"].presence || entry[:iso_day_of_week].presence
    return false if iso.nil?

    iso.to_i == iso_cwday
  end
  private_class_method :schedule_row_matches_iso_day?

  def self.api_aggregate_hours_string(office)
    wh = (office["working_hours"] || office[:working_hours]).to_s.strip
    bh = (office["break_hours"] || office[:break_hours]).to_s.strip
    return nil if wh.blank?

    [wh, bh.presence].compact.join(", ")
  end
  private_class_method :api_aggregate_hours_string

  def self.enrich_schedule_row(entry, calendar_iso: nil)
    row = entry.stringify_keys
    iso = calendar_iso || row["iso_day_of_week"].to_i
    row["iso_day_of_week"] = iso if calendar_iso
    row["weekday_short"] = WEEKDAY_SHORT_RU[iso] if iso.between?(1, 7)
    row
  end
  private_class_method :enrich_schedule_row
end
