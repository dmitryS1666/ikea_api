module Categories
  class AvailableFiltersImportService
    Result = Struct.new(:updated, :skipped, :errors, :total, keyword_init: true)

    def initialize(io)
      @io = io
    end

    def call
      return Result.new(updated: 0, skipped: 0, errors: 1, total: 0) unless @io.respond_to?(:read)

      raw = @io.read.to_s
      entries, parse_errors = parse_entries(raw)

      updated = 0
      skipped = 0
      errors = parse_errors
      updated_category_ids = []

      entries.each do |entry|
        unless entry.is_a?(Hash)
          errors += 1
          next
        end

        ikea_id = (entry["ikea_id"] || entry[:ikea_id] || entry["id"] || entry[:id]).to_s.strip
        if ikea_id.blank?
          skipped += 1
          next
        end

        category = Category.find_by(ikea_id: ikea_id)
        unless category
          skipped += 1
          next
        end

        filters = normalize_available_filters(entry["available_filters"] || entry[:available_filters])
        if category.available_filters != filters
          category.update!(available_filters: filters)
          updated += 1
          updated_category_ids << category.ikea_id
        else
          skipped += 1
        end
      rescue StandardError => e
        Rails.logger.error("[Categories::AvailableFiltersImportService] ikea_id=#{ikea_id} error=#{e.class}: #{e.message}")
        errors += 1
      end

      updated_category_ids.uniq.each do |category_id|
        ReindexCategoryFiltersJob.perform_later(category_id)
      end

      Result.new(
        updated: updated,
        skipped: skipped,
        errors: errors,
        total: entries.length
      )
    end

    private

    def parse_entries(raw)
      parse_errors = 0
      entries = []
      raw = raw.to_s.strip
      return [entries, parse_errors] if raw.blank?

      begin
        parsed = JSON.parse(raw)
        entries = normalize_parsed(parsed)
      rescue JSON::ParserError
        raw.split("\n").each do |line|
          next if line.strip.blank?
          begin
            parsed = JSON.parse(line)
            entries.concat(normalize_parsed(parsed))
          rescue JSON::ParserError
            parse_errors += 1
          end
        end
      end

      [entries, parse_errors]
    end

    def normalize_parsed(parsed)
      if parsed.is_a?(Hash) && parsed.key?("categories")
        Array(parsed["categories"])
      elsif parsed.is_a?(Hash) && parsed.key?("category")
        Array(parsed["category"])
      elsif parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        [parsed]
      else
        []
      end
    end

    def normalize_available_filters(filters)
      return [] if filters.blank?

      return filters if filters.is_a?(Array)
      return [filters] if filters.is_a?(Hash)

      if filters.is_a?(String)
        begin
          parsed = JSON.parse(filters)
          return parsed if parsed.is_a?(Array)
          return [parsed] if parsed.is_a?(Hash)
        rescue JSON::ParserError
          return []
        end
      end

      []
    end
  end
end
