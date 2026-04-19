namespace :products do
  desc "Export ALL products for weight update/recovery and launch job"
  task recover_missing_weights: :environment do
    limit = ENV['LIMIT']&.to_i
    
    # 1. Export SKUs (только без веса — в одной линии с джобой)
    skus = Product.where(weight: nil)
    skus = skus.limit(limit) if limit
    sku_list = skus.pluck(:sku)
    
    file_path = Rails.root.join("log", "missing_weights_skus_#{Time.now.to_i}.csv")
    File.write(file_path, sku_list.join("\n"))
    
    puts "Exported #{sku_list.size} SKUs to #{file_path}"
    
    # 2. Create Task and Job
    task = ParserTask.create!(
      task_type: "recover_missing_weights",
      status: "pending",
      limit: limit,
      payload: {
        sku_file_path: file_path.to_s,
        total_to_process: sku_list.size
      }
    )
    
    puts "Created ParserTask ##{task.id}"
    
    # 3. Launch Job
    RecoverMissingWeightsJob.perform_later(task_id: task.id, limit: limit, only_missing_weight: true)
    puts "Job launched with 2 threads and proxy rotation (via PlDetailsFetcher)"
  end
end
