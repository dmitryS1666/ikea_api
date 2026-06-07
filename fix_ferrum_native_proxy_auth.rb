#!/usr/bin/env ruby
# Fix Ferrum proxy auth in app/lib/pl_details_fetcher.rb.
# Replaces Chrome --proxy-server / extension auth with native Ferrum `proxy:` option.
# Creates backup: app/lib/pl_details_fetcher.rb.bak_native_proxy_<timestamp>

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

if src.include?("Using native Ferrum proxy") && src.include?("opts[:proxy] = ferrum_proxy")
  puts "Already patched: native Ferrum proxy auth is present."
  exit 0
end

# 1) Replace the old proxy_string + Chrome extension auth block.
#
# The old code starts with:
#   proxy_string = nil
#   if proxy_host.present? && proxy_port.present?
#     ...
# and ends right before:
#   browser_options = {
#
# We replace it with native Ferrum proxy options.
proxy_block_re = /
      proxy_string = nil\n
      if proxy_host\.present\? && proxy_port\.present\?\n
        .*?
      end\n
\s*
      browser_options = \{
/mx

replacement = <<~'RUBY'
      ferrum_proxy = nil
      if proxy_host.present? && proxy_port.present?
        ferrum_proxy = {
          host: proxy_host,
          port: proxy_port.to_i
        }

        if proxy_user.present? && proxy_pass.present?
          ferrum_proxy[:user] = proxy_user
          ferrum_proxy[:password] = proxy_pass
        end

        Rails.logger.debug(
          "PlDetailsFetcher.fetch_modal_with_headless_browser: " \
          "Using native Ferrum proxy: #{proxy_host}:#{proxy_port} " \
          "(auth=#{proxy_user.present?})"
        )
      end

      browser_options = {
RUBY

unless src.match?(proxy_block_re)
  abort <<~MSG
    Could not find old proxy_string block in #{path}.

    Please inspect this area manually:
      grep -n "proxy_string\\|browser_options = \\|Ferrum::Browser.new" app/lib/pl_details_fetcher.rb
  MSG
end

src = src.sub(proxy_block_re, replacement)

# 2) Remove leftover Chrome proxy/extension lines if they survived in a slightly different layout.
src.gsub!(/^\s*browser_options\["proxy-server"\] = proxy_string if proxy_string\n/, "")

# Remove a typical leftover extension block.
src.gsub!(
  /\n\s*if extension_dir\n\s*browser_options\["load-extension"\] = extension_dir\n\s*browser_options\["disable-extensions-except"\] = extension_dir\n\s*end\n/,
  "\n"
)

# Remove any remaining lines that only reference extension_dir in this method.
src.gsub!(/^\s*browser_options\["load-extension"\] = extension_dir\n/, "")
src.gsub!(/^\s*browser_options\["disable-extensions-except"\] = extension_dir\n/, "")

# 3) Add native proxy option to Ferrum opts before browser creation.
browser_new_line = '      browser = Ferrum::Browser.new(browser_options: browser_options, **opts)'
unless src.include?(browser_new_line)
  abort <<~MSG
    Could not find Ferrum::Browser.new line in #{path}.

    Please inspect manually:
      grep -n "Ferrum::Browser.new" app/lib/pl_details_fetcher.rb
  MSG
end

unless src.include?("opts[:proxy] = ferrum_proxy if ferrum_proxy.present?")
  src = src.sub(
    browser_new_line,
    "      opts[:proxy] = ferrum_proxy if ferrum_proxy.present?\n\n#{browser_new_line}"
  )
end

# Safety checks.
if src.include?("proxy_string") && src.scan(/proxy_string/).any?
  warn "WARNING: proxy_string still exists somewhere in file. Check if it is unrelated or stale:"
  warn src.lines.each_with_index.select { |line, _i| line.include?("proxy_string") }.map { |line, i| "#{i + 1}: #{line}" }.join
end

if src.include?("extension_dir")
  warn "WARNING: extension_dir still exists somewhere in file. Check if old Chrome extension auth remains:"
  warn src.lines.each_with_index.select { |line, _i| line.include?("extension_dir") }.map { |line, i| "#{i + 1}: #{line}" }.join
end

if src == original
  abort "No changes were made."
end

backup = "#{path}.bak_native_proxy_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Next checks:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n \"Using native Ferrum proxy\\|opts\\[:proxy\\]\\|proxy-server\\|extension_dir\" app/lib/pl_details_fetcher.rb"
