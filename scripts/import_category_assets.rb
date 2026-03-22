require 'json'

# Script to import category icons and pictograms
# Icons source: /home/sushi/Documents/ikea_api/icons

BASE_ICONS_DIR = Rails.root.join('icons').to_s
CATALOG_DIR = File.join(BASE_ICONS_DIR, 'Каталог')
PICTOGRAMS_DIR = Rails.root.join('Пиктограммы верхних категорий').to_s

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
  is_top = Array(cat.parent_ids).empty? || cat.is_important?
  
  attached_now = false
  
  # 1. Handle ICON (PNG)
  icon_path = nil
  if is_top
    potential_path = File.join(CATALOG_DIR, "#{name}.png")
    icon_path = potential_path if File.exist?(potential_path)
  else
    root_name = find_root_name(cat, top_map)
    if root_name
      potential_path = File.join(BASE_ICONS_DIR, root_name, "#{name}.png")
      icon_path = potential_path if File.exist?(potential_path)
    end
  end

  if icon_path
    begin
      cat.icon.purge if cat.icon.attached?
      cat.icon.attach(io: File.open(icon_path), filename: "#{name}.png", content_type: 'image/png')
      stats[:icons_attached] += 1
      attached_now = true
    rescue => e
      puts "Error attaching icon for #{name}: #{e.message}"
    end
  end

  # 2. Handle PICTOGRAM (SVG or PNG fallback) for top-level
  if is_top
    pic_path = File.join(PICTOGRAMS_DIR, "#{name}.svg")
    found_svg = File.exist?(pic_path)
    
    # If no SVG, try use the icon_path we found earlier as fallback
    final_pic_path = found_svg ? pic_path : icon_path
    
    if final_pic_path
      begin
        cat.pictogram.purge if cat.pictogram.attached?
        content_type = found_svg ? 'image/svg+xml' : 'image/png'
        ext = found_svg ? 'svg' : 'png'
        cat.pictogram.attach(io: File.open(final_pic_path), filename: "#{name}.#{ext}", content_type: content_type)
        stats[:pictograms_attached] += 1
        attached_now = true
        # puts "[OK] Attached pictogram (#{ext}) for: #{name}"
      rescue => e
        puts "Error attaching pictogram for #{name}: #{e.message}"
      end
    end
  end

  unless attached_now
    stats[:skipped] += 1
    # puts "[SKIP] No assets found for: #{name}"
  end
end

puts "\nIMPORT COMPLETE:"
puts "--------------------------"
puts "Icons attached: #{stats[:icons_attached]}"
puts "Pictograms attached (top-level): #{stats[:pictograms_attached]}"
puts "Categories skipped (no icon found): #{stats[:skipped]}"
puts "--------------------------"
