# frozen_string_literal: true

class ImportProductsFromJsonFileJob < ApplicationJob
  queue_as :parser

  def perform(file_name:, replace_category_links: false, limit: nil, offset: 0, log_every: 100)
    file_path = resolve_file_path(file_name)

    raise ArgumentError, "Файл не найден: #{file_path}" unless File.exist?(file_path)

    Rails.logger.info("ImportProductsFromJsonFileJob START file=#{file_path}")

    service = Products::JsonFileImportService.new(
      replace_category_links: replace_category_links,
      logger: Rails.logger
    )

    stats = {
      file_path: file_path.to_s,
      created: 0,
      updated: 0,
      unchanged: 0,
      skipped: 0,
      errors: 0,
      processed: 0
    }

    each_item(file_path, limit: limit, offset: offset).each_with_index do |item, index|
      result = service.process_item(item)

      case result.status
      when :created   then stats[:created] += 1
      when :updated   then stats[:updated] += 1
      when :unchanged then stats[:unchanged] += 1
      when :skipped   then stats[:skipped] += 1
      else                 stats[:errors] += 1
      end

      stats[:processed] += 1

      if (stats[:processed] % log_every).zero?
        Rails.logger.info("ImportProductsFromJsonFileJob progress processed=#{stats[:processed]} created=#{stats[:created]} updated=#{stats[:updated]} unchanged=#{stats[:unchanged]} errors=#{stats[:errors]}")
      end
    end

    Rails.logger.info("ImportProductsFromJsonFileJob FINISH #{stats.inspect}")
    stats
  end

  private

  def resolve_file_path(file_name)
    path = Pathname.new(file_name.to_s)
    return path.to_s if path.absolute?

    Rails.root.join(file_name.to_s).to_s
  end

  def each_item(file_path, limit:, offset:)
    Enumerator.new do |yielder|
      first_char = first_non_whitespace_char(file_path)

      case first_char
      when "["
        # Для обычного .json массива — грузим целиком.
        # Для больших файлов лучше использовать .jsonl.
        data = JSON.parse(File.read(file_path))
        Array(data).drop(offset.to_i).first(limit || data.size).each do |item|
          yielder << item
        end
      when "{"
        # Пробуем как одиночный JSON object.
        # Если не получилось — fallback на JSONL.
        begin
          parsed = JSON.parse(File.read(file_path))
          if parsed.is_a?(Array)
            parsed.drop(offset.to_i).first(limit || parsed.size).each { |item| yielder << item }
          else
            next if offset.to_i > 0
            next if limit.to_i == 0
            yielder << parsed
          end
        rescue JSON::ParserError
          each_jsonl_line(file_path, limit: limit, offset: offset) { |item| yielder << item }
        end
      else
        each_jsonl_line(file_path, limit: limit, offset: offset) { |item| yielder << item }
      end
    end
  end

  def each_jsonl_line(file_path, limit:, offset:)
    processed = 0
    skipped = 0

    File.foreach(file_path) do |line|
      line = line.to_s.strip
      next if line.blank?

      if skipped < offset.to_i
        skipped += 1
        next
      end

      break if limit.present? && processed >= limit.to_i

      yield JSON.parse(line)
      processed += 1
    rescue JSON::ParserError => e
      Rails.logger.error("ImportProductsFromJsonFileJob JSON parse error: #{e.message} line=#{line.truncate(300)}")
      next
    end
  end

  def first_non_whitespace_char(file_path)
    File.open(file_path, "r:utf-8") do |f|
      until f.eof?
        ch = f.getc
        return ch unless ch =~ /\s/
      end
    end
    nil
  end
end
