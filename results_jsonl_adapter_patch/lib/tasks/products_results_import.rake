namespace :products do
  desc 'Queue import for results.jsonl / flat product JSONL payloads'
  task :import_results_jsonl, [:file_path, :force_full] => :environment do |_t, args|
    file_path = args[:file_path].to_s
    force_full = ActiveModel::Type::Boolean.new.cast(args[:force_full])

    raise ArgumentError, 'Usage: bundle exec rake products:import_results_jsonl[/absolute/path/to/results.jsonl,true]' if file_path.blank?
    raise ArgumentError, "File not found: #{file_path}" unless File.exist?(file_path)

    task_record = ParserTask.create!(
      task_type: 'extended_attrs_import',
      status: 'pending',
      payload: {
        file_path: file_path,
        original_name: File.basename(file_path),
        force_full: force_full,
        format: 'results_jsonl',
        trust_images: true,
        cursor: 0
      }
    )

    job = ImportExtendedAttributesFromFileJob.perform_later(task_id: task_record.id)
    task_record.update!(job_id: job.job_id) if job.respond_to?(:job_id)

    puts "Queued ParserTask ##{task_record.id} for #{file_path}"
    puts "Job ID: #{job.job_id}" if job.respond_to?(:job_id)
  end
end
