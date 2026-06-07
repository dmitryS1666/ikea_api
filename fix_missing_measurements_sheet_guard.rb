#!/usr/bin/env ruby
# Minimal fixer for missing try_open_measurements_sheet! call in PlDetailsFetcher.
#
# It replaces:
#   measurements_opened = try_open_measurements_sheet!(browser)
#
# with a safe guarded call:
#   measurements_opened =
#     if respond_to?(:try_open_measurements_sheet!, true)
#       try_open_measurements_sheet!(browser)
#     else
#       Rails.logger.debug "... skipped ..."
#       false
#     end
#
# Usage from Rails project root:
#   ruby -c fix_missing_measurements_sheet_guard.rb
#   ruby fix_missing_measurements_sheet_guard.rb
#   ruby -c app/lib/pl_details_fetcher.rb

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

if src.include?("measurements sheet skipped: try_open_measurements_sheet! is not defined")
  puts "Already patched: safe measurements guard is present."
  exit 0
end

old = "      measurements_opened = try_open_measurements_sheet!(browser)\n"

new = <<~'RUBY'
      measurements_opened =
        if respond_to?(:try_open_measurements_sheet!, true)
          try_open_measurements_sheet!(browser)
        else
          Rails.logger.debug(
            "PlDetailsFetcher.fetch_modal_with_headless_browser: " \
            "measurements sheet skipped: try_open_measurements_sheet! is not defined"
          )
          false
        end
RUBY

unless src.include?(old)
  abort <<~MSG
    Could not find exact measurements call.

    Please inspect manually:
      grep -n "try_open_measurements_sheet\\|measurements_opened" app/lib/pl_details_fetcher.rb
  MSG
end

src = src.sub(old, new)

backup = "#{path}.bak_measurements_guard_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Check:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n \"measurements sheet skipped\\|try_open_measurements_sheet\\|measurements_opened\" app/lib/pl_details_fetcher.rb"
