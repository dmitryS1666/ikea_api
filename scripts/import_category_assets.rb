require 'json'

# Script to import category icons and pictograms
# Icons source: /home/sushi/Documents/ikea_api/icons

BASE_ICONS_DIR = '/home/sushi/Documents/ikea_api/icons'
CATALOG_DIR = File.join(BASE_ICONS_DIR, 'Каталог')

puts "Starting category assets import..."

# 1. Build a map of top-level categories for easy lookup
top_categories = Category.where("parent_ids IS NULL OR parent_ids::text = '[]' OR parent_ids::text = ''")
top_map = {}
top_categories.each { |c| top_map[c.ikea_id] = c.translated_name }

def find_root_name(cat, top_map)
  p_ids = Array(cat.parent_ids)
  
  return nil if p_ids.empty?
  
  # The first ID in parent_ids should be the root
  root_id = p_ids.first
  top_map[root_id]
end

stats = { icons_attached: 0, pictograms_attached: 0, skipped: 0 }

Category.find_each do |cat|
  name = cat.translated_name.to_s.strip
  is_top = Array(cat.parent_ids).empty?
  
  icon_path = nil
  
  if is_top
    # Search in Katalog for top level
    potential_path = File.join(CATALOG_DIR, "#{name}.png")
    icon_path = potential_path if File.exist?(potential_path)
  else
    # Search in root-named folder for subcategories
    root_name = find_root_name(cat, top_map)
    if root_name
      potential_path = File.join(BASE_ICONS_DIR, root_name, "#{name}.png")
      icon_path = potential_path if File.exist?(potential_path)
    end
  end

  if icon_path
    # Attach icon
    begin
      cat.icon.purge if cat.icon.attached?
      cat.icon.attach(io: File.open(icon_path), filename: "#{name}.png", content_type: 'image/png')
      stats[:icons_attached] += 1
      
      # Also attach pictogram for top-level
      if is_top
        cat.pictogram.purge if cat.pictogram.attached?
        cat.pictogram.attach(io: File.open(icon_path), filename: "#{name}_pictogram.png", content_type: 'image/png')
        stats[:pictograms_attached] += 1
      end
      
      # puts "Attached assets for: #{name}"
    rescue => e
      puts "Error attaching assets for #{name}: #{e.message}"
    end
  else
    stats[:skipped] += 1
    # puts "No icon found for: #{name}"
  end
end

puts "\nIMPORT COMPLETE:"
puts "--------------------------"
puts "Icons attached: #{stats[:icons_attached]}"
puts "Pictograms attached (top-level): #{stats[:pictograms_attached]}"
puts "Categories skipped (no icon found): #{stats[:skipped]}"
puts "--------------------------"
