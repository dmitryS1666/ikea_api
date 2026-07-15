# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

Seeds::AdminRoleUsers.call.each do |result|
  icon = result[:status] == :saved ? "✅" : "⚠️"
  puts "#{icon} #{result[:username]}: #{result[:status]}#{": #{result[:error]}" if result[:error]}"
end

puts "⚠️  Для первичного production seed обязательны ENV DIRECTOR_PASSWORD, SITE_ADMIN_PASSWORD и т.д."

LegalPage.seed_defaults!
puts "✅ Правовые страницы (дефолтный набор): проверены/созданы."
