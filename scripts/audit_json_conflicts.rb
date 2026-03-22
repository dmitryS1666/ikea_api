require 'json'

# Script to audit the Master JSON for ID/Name conflicts
MASTER_JSON = 'ikeya_categories_final_with_merges_and_deletions.json'

unless File.exist?(MASTER_JSON)
  puts "Error: #{MASTER_JSON} not found."
  exit 1
end

json_data = JSON.parse(File.read(MASTER_JSON))
conflicts = Hash.new { |h, k| h[k] = Set.new }

def traverse(nodes, conflicts)
  nodes.each do |node|
    id = node['ikea_id']
    name = node['effective_name']
    
    if id
      conflicts[id].add(name)
    end
    
    if node['children'] && node['children'].any?
      traverse(node['children'], conflicts)
    end
  end
end

traverse(json_data['categories'], conflicts)

conflicting_ids = conflicts.select { |id, names| names.size > 1 }

if conflicting_ids.any?
  puts "!!! FOUND CONFLICTING NAMES FOR THE SAME IKEA_ID !!!"
  puts "----------------------------------------------------"
  conflicting_ids.each do |id, names|
    puts "ID: #{id} is used for multiple names:"
    names.each { |name| puts "  - #{name}" }
    puts "----------------------------------------------------"
  end
  puts "Total conflicting IDs: #{conflicting_ids.size}"
else
  puts "No name conflicts found for unique IKEA_IDs."
end
