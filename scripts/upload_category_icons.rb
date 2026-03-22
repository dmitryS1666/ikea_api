require 'find'

# Script to upload category icons from a directory structure.
# Matches files to categories by translated_name.

icons_root = '/home/sushi/Documents/ikea_api/icons'
supported_extensions = ['.png', '.jpg', '.jpeg', '.svg', '.webp']

unless Dir.exist?(icons_root)
  puts "Error: Icons directory #{icons_root} not found."
  exit 1
end

stats = { found: 0, attached: 0, skipped: 0, errors: 0 }

puts "Scanning icons in #{icons_root}..."

Find.find(icons_root) do |path|
  next if File.directory?(path)
  
  ext = File.extname(path).downcase
  next unless supported_extensions.include?(ext)
  
  category_name = File.basename(path, ext).strip
  
  # Find categories by translated_name (case-insensitive)
  categories = Category.where('LOWER(translated_name) = ?', category_name.downcase).where(is_deleted: [false, nil])
  
  if categories.any?
    stats[:found] += 1
    categories.each do |cat|
      begin
        # Purge old icon if exists
        cat.icon.purge if cat.icon.attached?
        
        # Attach new icon
        cat.icon.attach(
          io: File.open(path),
          filename: File.basename(path),
          content_type: "image/#{ext.sub('.', '')}"
        )
        
        puts "Attached icon to ID #{cat.ikea_id}: '#{cat.translated_name}'"
        stats[:attached] += 1
      rescue => e
        puts "Error attaching icon to #{cat.ikea_id}: #{e.message}"
        stats[:errors] += 1
      end
    end
  else
    # puts "No category found for icon: '#{category_name}'"
    stats[:skipped] += 1
  end
end

puts "\nICON UPLOAD COMPLETE:"
puts "----------------------"
puts "Unique icon names matched: #{stats[:found]}"
puts "Total icons attached: #{stats[:attached]}"
puts "Icons without matching categories: #{stats[:skipped]}"
puts "Errors encountered: #{stats[:errors]}"
puts "----------------------"
