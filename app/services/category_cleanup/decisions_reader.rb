require 'roo'

module CategoryCleanup
  class DecisionsReader < Base
    ParsedDecision = Struct.new(
      :source_row_no,
      :source_ikea_id,
      :source_url,
      :raw_status,
      :action,
      :target_row_no,
      :target_ikea_id,
      keyword_init: true
    )

    MERGE_BY_ROW_REGEX = /схлопываем\s+с\s+категорией.*?в\s+строке\s+(\d+)/i
    MERGE_BY_ID_REGEX  = /схлопываем\s+с\s+категорией\s+с?\s*(\d+)/i

    def call
      xlsx = Roo::Spreadsheet.open(DECISIONS_FILE.to_s)
      sheet = xlsx.sheet(0)

      parsed = []

      (2..sheet.last_row).each do |row_index|
        row = sheet.row(row_index)

        source_row_no = row[0].to_i
        source_ikea_id = row[1].to_s.strip.presence
        source_url = normalize_url(row[2])
        raw_status = row[3].to_s.strip

        next if source_row_no.zero?
        next if raw_status.blank?

        decision = parse_status(raw_status)

        parsed << ParsedDecision.new(
          source_row_no: source_row_no,
          source_ikea_id: source_ikea_id,
          source_url: source_url,
          raw_status: raw_status,
          action: decision[:action],
          target_row_no: decision[:target_row_no],
          target_ikea_id: decision[:target_ikea_id]
        )
      end

      parsed
    end

    private

    def normalize_url(value)
      url = value.to_s.strip
      return nil if url.blank? || url.casecmp('нет').zero?
      url
    end

    def parse_status(raw_status)
      text = raw_status.to_s.strip

      return { action: 'delete', target_row_no: nil, target_ikea_id: nil } if text =~ /удаляем/i
      return { action: 'keep', target_row_no: nil, target_ikea_id: nil } if text =~ /оставляем/i

      if (match = text.match(MERGE_BY_ROW_REGEX))
        return {
          action: 'merge',
          target_row_no: match[1].to_i,
          target_ikea_id: nil
        }
      end

      if (match = text.match(MERGE_BY_ID_REGEX))
        return {
          action: 'merge',
          target_row_no: nil,
          target_ikea_id: match[1]
        }
      end

      { action: 'review', target_row_no: nil, target_ikea_id: nil }
    end
  end
end
