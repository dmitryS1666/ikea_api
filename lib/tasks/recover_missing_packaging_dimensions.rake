# frozen_string_literal: true

namespace :products do
  desc "Восполнить measurements_modal / размеры упаковок (ExtendedAttributesFetchService). LIMIT= optional"
  task recover_missing_packaging_dimensions: :environment do
    limit = ENV["LIMIT"]&.to_i
    limit = nil if limit.present? && !limit.positive?

    task = ParserTask.create!(
      task_type: "recover_missing_packaging_dimensions",
      status: "pending",
      limit: limit,
      payload: {
        total_to_process: nil,
        only_missing_packaging_dimensions: true
      }
    )

    puts "ParserTask ##{task.id} created"
    RecoverMissingPackagingDimensionsJob.perform_later(
      task_id: task.id,
      limit: limit,
      only_missing_packaging_dimensions: true
    )
    puts "RecoverMissingPackagingDimensionsJob enqueued (queue: parser)"
  end
end
