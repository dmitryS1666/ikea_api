require 'csv'

output_path = '/home/sushi/Documents/ikea_api/all_db_categories_export.csv'

CSV.open(output_path, "wb", col_sep: "|") do |csv|
  # Header
  csv << ["ikea_id", "translated_name (RU)", "name (Original/PL)", "is_deleted"]
  
  # Data
  Category.order(:ikea_id).each do |cat|
    csv << [
      cat.ikea_id,
      cat.translated_name,
      cat.name,
      cat.is_deleted ? "Yes" : "No"
    ]
  end
end

puts "Exported #{Category.count} categories to #{output_path}"
