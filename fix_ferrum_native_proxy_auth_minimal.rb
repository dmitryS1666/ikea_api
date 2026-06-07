#!/usr/bin/env ruby
# Minimal fixer for PlDetailsFetcher Ferrum proxy auth.
# It keeps existing proxy parsing, but stops passing auth proxy via Chrome --proxy-server/extension
# and passes it through native Ferrum `proxy:` option instead.
#
# Usage from Rails project root:
#   ruby -c fix_ferrum_native_proxy_auth_minimal.rb
#   ruby fix_ferrum_native_proxy_auth_minimal.rb
#   ruby -c app/lib/pl_details_fetcher.rb

path = File.expand_path("app/lib/pl_details_fetcher.rb", Dir.pwd)
abort "File not found: #{path}" unless File.exist?(path)

src = File.read(path)
original = src.dup

if src.include?("opts[:proxy] = ferrum_proxy if ferrum_proxy.present?") &&
   src.include?("Using native Ferrum proxy")
  puts "Already patched."
  exit 0
end

# 1) Insert ferrum_proxy block right before browser_options = {.
needle = "      browser_options = {\n"
insert = <<~'RUBY'
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

RUBY

unless src.include?(needle)
  abort "Could not find `browser_options = {` block. Run: grep -n \"browser_options =\" app/lib/pl_details_fetcher.rb"
end

src = src.sub(needle, insert + needle)

# 2) Stop passing proxy through Chrome CLI. Auth proxies must go through Ferrum native proxy option.
src.gsub!(/^\s*browser_options\["proxy-server"\] = proxy_string if proxy_string\n/, "")

# 3) Stop loading generated proxy-auth extension. Native Ferrum proxy handles auth.
src.gsub!(
  /\n\s*if extension_dir\n\s*browser_options\["load-extension"\] = extension_dir\n\s*browser_options\["disable-extensions-except"\] = extension_dir\n\s*end\n/,
  "\n"
)

# 4) Add opts[:proxy] before browser creation.
browser_line = "      browser = Ferrum::Browser.new(browser_options: browser_options, **opts)\n"
unless src.include?(browser_line)
  abort "Could not find Ferrum::Browser.new line. Run: grep -n \"Ferrum::Browser.new\" app/lib/pl_details_fetcher.rb"
end

src = src.sub(browser_line, "      opts[:proxy] = ferrum_proxy if ferrum_proxy.present?\n\n" + browser_line)

# Safety: ensure old proxy-server line is gone.
if src.include?('browser_options["proxy-server"] = proxy_string')
  abort "Old proxy-server line is still present; aborting to avoid half-patch."
end

backup = "#{path}.bak_native_proxy_minimal_#{Time.now.strftime('%Y%m%d%H%M%S')}"
File.write(backup, original)
File.write(path, src)

puts "Patched #{path}"
puts "Backup: #{backup}"
puts
puts "Check:"
puts "  ruby -c app/lib/pl_details_fetcher.rb"
puts "  grep -n \"Using native Ferrum proxy\\|opts\\[:proxy\\]\\|proxy-server\\|load-extension\\|disable-extensions-except\" app/lib/pl_details_fetcher.rb"
