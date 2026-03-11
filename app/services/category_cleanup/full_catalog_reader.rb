require 'roo'

module CategoryCleanup
  class FullCatalogReader < Base
    Row = Struct.new(
      :row_no,
      :raw_name,
      :seo_name,
      :depth,
      :path,
      keyword_init: true
    )

    def call
      xlsx = Roo::Spreadsheet.open(FULL_CATALOG_FILE.to_s)
      sheet = xlsx.sheet(0)

      rows = []
      stack = {}

      (1..sheet.last_row).each do |row_no|
        values = sheet.row(row_no)

        row_data = extract_catalog_row(row_no, values)
        next if row_data.nil?

        stack[row_data[:depth]] = row_data[:name]
        stack.keys.select { |k| k > row_data[:depth] }.each { |k| stack.delete(k) }

        path = stack.sort_by(&:first).map(&:last).join(' > ')

        rows << Row.new(
          row_no: row_no,
          raw_name: row_data[:name],
          seo_name: row_data[:seo_name],
          depth: row_data[:depth],
          path: path
        )
      end

      rows
    end

    private

    def extract_catalog_row(_row_no, values)
      seo_name = values[7].to_s.strip.presence

      hierarchy_cells = values[0..6]

      hierarchy_pairs = hierarchy_cells.each_with_index.map do |value, index|
        cleaned = normalize_catalog_cell(value)
        [index, cleaned]
      end.select { |(_, value)| value.present? }

      meaningful_pairs = hierarchy_pairs.reject do |(_, value)|
        technical_cell?(value)
      end

      selected_pair = meaningful_pairs.first || hierarchy_pairs.first

      return nil if selected_pair.nil? && seo_name.blank?

      if selected_pair.present?
        col_index, raw_value = selected_pair
        name = raw_value
        depth = col_index
      else
        name = seo_name
        depth = 0
      end

      name = cleanup_catalog_name(name)
      return nil if name.blank?

      {
        name: name,
        seo_name: seo_name,
        depth: depth
      }
    end

    def normalize_catalog_cell(value)
      value.to_s
           .gsub(/^📂\s*/, '')
           .gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
           .presence
    end

    def technical_cell?(value)
      text = value.to_s.strip

      return true if text.blank?
      return true if text.match?(/\A\d+\z/)                # "1", "2", ...
      return true if text.match?(/\A[-–—]+\z/)
      return true if text.downcase.in?(%w[nan null none])

      false
    end

    def cleanup_catalog_name(value)
      value.to_s
           .gsub(/^└─+/, '')
           .gsub(/^📂\s*/, '')
           .strip
           .presence
    end
  end
end
