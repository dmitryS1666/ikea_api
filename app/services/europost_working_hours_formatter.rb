# frozen_string_literal: true

# Builds human-readable working_hours and optional structured fields for Europost pickup points.
# Preference: schedules (from GET /api/external/stores) -> working_hours + break_hours -> legacy Info1-3.
class EuropostWorkingHoursFormatter
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
    out[:schedules] = raw_schedules if raw_schedules.is_a?(Array) && raw_schedules.any?
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
    return [] unless raw.is_a?(Array)

    raw.select do |s|
      next false unless s.is_a?(Hash)

      s["work_time"].present? || s[:work_time].present? ||
        s["is_working"].present? || s[:is_working].present?
    end
  end
  private_class_method :normalized_schedules

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
end
