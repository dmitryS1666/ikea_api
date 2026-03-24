class ImportExtendedAttributesFromFileJob < ApplicationJob
  queue_as :parser

  CURSOR_SAVE_EVERY = 50

  def perform(task_id:)
    task = ParserTask.find(task_id)
    payload = task.payload || {}
    file_path = payload['file_path']
    force_full = payload['force_full'] == true
    format = payload['format']
    trust_images = payload['trust_images'] == true
    cursor = payload['cursor'].to_i

    raise "Import file not found: #{file_path}" if file_path.blank? || !File.exist?(file_path)

    task.mark_as_running! unless task.status == 'running'

    total_lines = task.limit.presence || count_lines(file_path)
    task.update!(limit: total_lines) if task.limit.blank?

    importer = Products::ExtendedAttributesImportService.new(
      force_full: force_full,
      format: format,
      trust_images: trust_images
    )

    processed_since_cursor = 0
    last_cursor = cursor

    File.foreach(file_path).with_index do |line, idx|
      next if idx < cursor
      break if task_stopped?(task)

      line = line.to_s.strip
      if line.blank?
        processed_since_cursor += 1
        last_cursor = idx + 1
        processed_since_cursor = update_cursor(task, payload, last_cursor, processed_since_cursor)
        next
      end

      begin
        item = JSON.parse(line)
      rescue JSON::ParserError
        task.increment_errors!
        processed_since_cursor += 1
        last_cursor = idx + 1
        processed_since_cursor = update_cursor(task, payload, last_cursor, processed_since_cursor)
        next
      end

      result = importer.process_item(item)
      task.increment_processed!
      task.increment_created! if result == :created
      task.increment_updated! if result == :updated
      task.increment_errors! if result == :error

      processed_since_cursor += 1
      last_cursor = idx + 1
      processed_since_cursor = update_cursor(task, payload, last_cursor, processed_since_cursor)
    end

    payload['cursor'] = last_cursor
    task.update!(payload: payload)
    return if task_stopped?(task)

    task.mark_as_completed!(processed: task.processed, updated: task.updated, errors: task.error_count)
  rescue StandardError => e
    if e.message == 'Task was stopped manually'
      Rails.logger.info "ImportExtendedAttributesFromFileJob: Task #{task.id} stopped manually"
      return
    end

    Rails.logger.error "ImportExtendedAttributesFromFileJob error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
    if task
      payload ||= {}
      payload['cursor'] = last_cursor if defined?(last_cursor)
      task.update!(payload: payload)
      task.mark_as_failed!(e.message)
    end
    notify_error('extended_attrs_import', e)
  end

  private

  def count_lines(path)
    count = 0
    File.foreach(path) { |_line| count += 1 }
    count
  end

  def update_cursor(task, payload, next_cursor, processed_since_cursor)
    return processed_since_cursor if processed_since_cursor < CURSOR_SAVE_EVERY

    payload['cursor'] = next_cursor
    task.update!(payload: payload)
    0
  end
end
