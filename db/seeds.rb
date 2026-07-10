# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Дефолтные пользователи по ролевой модели
seed_users = [
  {
    key: "DIRECTOR",
    username: "director",
    email: "director@ikea_api.local",
    role: "admin"
  },
  {
    key: "SITE_ADMIN",
    username: "site_admin",
    email: "site_admin@ikea_api.local",
    role: "site_admin"
  },
  {
    key: "REQUEST_MANAGER",
    username: "requests_manager",
    email: "requests_manager@ikea_api.local",
    role: "manager_requests"
  },
  {
    key: "CONTENT_MANAGER",
    username: "content_manager",
    email: "content_manager@ikea_api.local",
    role: "content_manager"
  },
  {
    key: "ACCOUNTANT",
    username: "accountant",
    email: "accountant@ikea_api.local",
    role: "accountant"
  },
  {
    key: "TECHNICIAN",
    username: "technician",
    email: "technician@ikea_api.local",
    role: "technician"
  },
  {
    key: "OBSERVER",
    username: "observer",
    email: "observer@ikea_api.local",
    role: "observer"
  }
]

seed_users.each do |entry|
  password = ENV["#{entry[:key]}_PASSWORD"] || "ChangeMe_#{entry[:key].downcase}_123"
  email = ENV["#{entry[:key]}_EMAIL"] || entry[:email]

  user = User.find_or_initialize_by(username: entry[:username])
  user.assign_attributes(
    email: email,
    password: password,
    password_confirmation: password,
    role: entry[:role],
    is_active: true
  )

  if user.save
    puts "✅ Пользователь роли '#{entry[:role]}' создан/обновлен:"
    puts "   Username: #{user.username}"
    puts "   Email: #{user.email}"
    puts "   Role: #{user.role}"
  else
    puts "❌ Ошибка при создании пользователя #{entry[:username]}:"
    user.errors.full_messages.each do |message|
      puts "   - #{message}"
    end
  end
end

puts ""
puts "⚠️  ВНИМАНИЕ: задайте пароли через ENV (*_PASSWORD) для production."

LegalPage.seed_defaults!
puts "✅ Правовые страницы (дефолтный набор): проверены/созданы."
